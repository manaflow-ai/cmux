import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import GhosttyNextKit
import QuartzCore

/// FRAME OWNER REFACTOR S4 (`motion.frameOwner.terminals`, ``TerminalDragTunables/framesOwnedByCommit``): one per
/// window. The present and the new bounds go together under `[CATransaction lock]` (Ghostty's call-site rule for
/// `ghostty_surface_host_frame`). A terminal whose size changes asks Ghostty for a frame at the new size (``TerminalSurfaceView/place(_:anchor:)``)
/// and keeps its old bounds and old frame. Just before Core Animation's commit of every main run-loop turn while a
/// request waits (a run-loop observer at ``passOrder``), the presenter's pass asks each waiting terminal for that frame
/// (`ghostty_surface_host_frame`): a drawn one becomes the layer's contents and the view takes the new bounds in that
/// same commit; one not drawn yet keeps both (ready-or-keep). A size asked during AppKit's display cycle (inside that
/// turn's commit) is presented from the next turn: the renderer draws it meanwhile. The main thread never waits for a frame. Chromium does the same at a resize: the browser compositor
/// shows a new size only with a frame the renderer submitted for it and keeps the old surface until then.
///
/// Requests of one refresh form a group that presents together for at most ``groupTicks`` refreshes, so two terminals
/// beside one divider land in the same commit. A request kept more than ``keepLimit`` refreshes takes its bounds
/// anyway (counted in ``Stats/fallbacks``). One refresh after a commit that changed a terminal's shown size, the presenter
/// tells Ghostty that commit is done (`ghostty_surface_host_frame_committed`), so the terminal's echo goes to the screen
/// off the main thread again. A new display scale is the same request: the layer keeps its scale until the frame drawn
/// at the new one shows (``TerminalSurfaceView/holdsScale(_:)``). The lock span holds only the present and the
/// geometry; what follows the new size runs after it (``TerminalSurfaceView/frameDidLand()``).
final class TerminalFramePresenter {
    /// Refreshes a group of requests waits for its slowest member.
    static let groupTicks: UInt64 = 2
    /// Refreshes a request keeps its old size before it takes its bounds without its frame.
    static let keepLimit: UInt64 = 6
    /// The pass's run-loop order: just before Core Animation's commit (2,000,000), after the turn's other work.
    static let passOrder: CFIndex = 1_999_999
    /// Refreshes a terminal whose bounds changed without a present is watched for its frame.
    static let watchLimit = 240

    /// What the presenters did, cumulative (diagnostics and tests).
    struct Stats: Equatable {
        var passes = 0
        /// Requests that took their bounds with their frame in one commit.
        var presented = 0
        /// Passes that kept a request at its old size (its frame was not drawn yet).
        var keeps = 0
        /// Passes that kept a ready request because another of its group was not ready.
        var groupWaits = 0
        /// Requests that took their bounds without their frame after ``keepLimit`` passes.
        var fallbacks = 0
        var longestPass: Duration = .zero
    }

    /// What this window's presenter did, cumulative.
    private(set) var stats = Stats()

    private struct Request {
        weak var view: TerminalSurfaceView?
        /// The refresh it was made in: its group.
        var epoch: UInt64
    }

    private struct Watch {
        weak var view: TerminalSurfaceView?
        var ticks = 0
    }

    private weak var window: NSWindow?
    private var requests: [ObjectIdentifier: Request] = [:]
    /// Terminals whose shown size changed outside a present (a first frame, a reveal, a fallback), until their layer
    /// shows the host size.
    private var watched: [ObjectIdentifier: Watch] = [:]
    /// Terminals whose shown size changed in a commit that is done by the next refresh.
    private var commits: [ObjectIdentifier: Watch] = [:]
    private var epoch: UInt64 = 0
    /// The pass before each commit, installed while a request waits.
    private var passObserver: MainRunLoopObserver?
    private lazy var client = FrameClient(owner: "Terminal.framePresenter", isAnimation: false, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    private init(window: NSWindow) {
        self.window = window
    }

    private static var associationKey: UInt8 = 0

    /// `window`'s presenter, made on first use and kept by the window.
    static func forWindow(_ window: NSWindow) -> TerminalFramePresenter {
        if let presenter = objc_getAssociatedObject(window, &associationKey) as? TerminalFramePresenter { return presenter }
        let presenter = TerminalFramePresenter(window: window)
        objc_setAssociatedObject(window, &associationKey, presenter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return presenter
    }

    /// `view` asked Ghostty for a frame at a new size: the next commits present it with its bounds, or keep both.
    func request(_ view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        requests[id] = Request(view: view, epoch: epoch)
        watched[id] = nil
        armPass()
        client.activate()
    }

    /// `view`'s shown size changed outside a present: its commit is reported once its layer shows the host size.
    func watch(_ view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        guard requests[id] == nil else { return }
        watched[id] = Watch(view: view)
        client.activate()
    }

    /// `view` stops owning its frame through this window (the switch, another window).
    func cancel(_ view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        requests[id] = nil
        watched[id] = nil
        commits[id] = nil
    }

    /// Whether `view` waits for a present here.
    func isWaiting(_ view: TerminalSurfaceView) -> Bool { requests[ObjectIdentifier(view)] != nil }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// What this presenter holds for `view` (`debug.motion` trace): "request" (a size waits for its frame), "watch"
    /// (its shown size changed outside a present), "commit" (its commit is reported at the next refresh), or "-".
    func debugState(of view: TerminalSurfaceView) -> String {
        let id = ObjectIdentifier(view)
        if requests[id] != nil { return "request" }
        if watched[id] != nil { return "watch" }
        if commits[id] != nil { return "commit" }
        return "-"
    }
    #endif

    // MARK: Frames

    /// One refresh: the commits of earlier passes are done (``commits``), and watched terminals are read.
    private func tick() -> Bool {
        epoch &+= 1
        if !commits.isEmpty {
            for (_, done) in commits { done.view?.hostFrameCommitted() }
            commits.removeAll(keepingCapacity: true)
        }
        for (id, watch) in watched {
            guard let view = watch.view else {
                watched[id] = nil
                continue
            }
            switch view.hostFrame(present: false) {
            case GHOSTTY_HOST_FRAME_SHOWN:
                watched[id] = nil
                commits[id] = watch
            case GHOSTTY_HOST_FRAME_HIDDEN:
                // Shown again, it is watched again (``TerminalSurfaceView/updateOcclusion()``).
                watched[id] = nil
            case GHOSTTY_HOST_FRAME_READY:
                // Its bounds already have the host size (they were given without a present): the frame fits them.
                CATransaction.lock()
                _ = view.hostFrame(present: true)
                CATransaction.unlock()
            default:
                var next = watch
                next.ticks += 1
                watched[id] = next.ticks > Self.watchLimit ? nil : next
            }
        }
        return !requests.isEmpty || !watched.isEmpty || !commits.isEmpty
    }

    /// Installs the pass before each commit while a request waits. An observer never wakes the run loop: the
    /// display link's ticks (``client``) bring a turn, and its commit, each refresh.
    private func armPass() {
        guard passObserver == nil else { return }
        passObserver = MainRunLoopObserver(activities: [.beforeWaiting, .exit], order: Self.passOrder) { [weak self] _ in
            self?.pass()
        }
    }

    /// Before this turn's commit: each waiting terminal shows its frame at the new size with its new bounds, or keeps
    /// both. It never waits; a terminal that lands short asks for its newest size here (a grid report, as any size).
    func pass() { // perf-hot: 1ms motion-frame
        guard !requests.isEmpty else {
            passObserver = nil
            return
        }
        let started = ContinuousClock.now
        stats.passes += 1
        // A group (the requests of one refresh) waits for its slowest member while it is younger than `groupTicks`.
        var waitingGroups: [UInt64] = []
        for (_, request) in requests where !waitingGroups.contains(request.epoch) {
            guard let view = request.view else { continue }
            if !Self.isReady(view.hostFrame(present: false)) { waitingGroups.append(request.epoch) }
        }
        for (id, request) in requests {
            guard let view = request.view else {
                requests[id] = nil
                continue
            }
            let age = epoch &- request.epoch
            if waitingGroups.contains(request.epoch), age < Self.groupTicks {
                if Self.isReady(view.hostFrame(present: false)) { stats.groupWaits += 1 }
                continue
            }
            // Ghostty's call-site rule: the present and the new bounds under the Core Animation lock, so no off-main
            // commit of another terminal can ship this one's new frame with its old bounds in between.
            CATransaction.lock()
            let shown = view.hostFrame(present: true)
            let presented = shown == GHOSTTY_HOST_FRAME_PRESENTED || shown == GHOSTTY_HOST_FRAME_SHOWN
            // Cleared before the frame changes: a request the new frame makes for this view stays.
            if presented { requests[id] = nil }
            let followUp = presented ? view.landRequestedFrame() : false
            CATransaction.unlock()
            if presented {
                stats.presented += 1
                landed(view, id: id, watch: false, followUp: followUp)
                continue
            }
            switch shown {
            case GHOSTTY_HOST_FRAME_NONE, GHOSTTY_HOST_FRAME_HIDDEN:
                // Nothing to keep: the bounds go now; a frame that comes later fits them.
                land(view, id: id, watch: shown == GHOSTTY_HOST_FRAME_NONE)
            default:
                stats.keeps += 1
                if age > Self.keepLimit {
                    stats.fallbacks += 1
                    land(view, id: id, watch: true)
                }
            }
        }
        if requests.isEmpty { passObserver = nil }
        stats.longestPass = max(stats.longestPass, started.duration(to: .now))
    }

    /// The view takes the size its shown frame has; one that wants another size since asks for it now (a new
    /// request, presented from the next turn).
    private func land(_ view: TerminalSurfaceView, id: ObjectIdentifier, watch: Bool) {
        requests[id] = nil
        landed(view, id: id, watch: watch, followUp: view.landRequestedFrame())
    }

    private func landed(_ view: TerminalSurfaceView, id: ObjectIdentifier, watch: Bool, followUp: Bool) {
        // A request the landing made for this view owns it; it is not watched beside it.
        if watch, requests[id] == nil { watched[id] = Watch(view: view) } else if !watch { commits[id] = Watch(view: view) }
        // Outside the lock span: what follows the new size and reads Ghostty under the terminal's lock.
        view.frameDidLand()
        if followUp { view.requestWantedFrame() }
    }

    private static func isReady(_ state: ghostty_host_frame_e) -> Bool {
        state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_SHOWN
            || state == GHOSTTY_HOST_FRAME_NONE || state == GHOSTTY_HOST_FRAME_HIDDEN
    }
}
