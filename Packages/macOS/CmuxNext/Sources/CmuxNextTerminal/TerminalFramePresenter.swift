import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import GhosttyNextKit
import QuartzCore

/// FRAME OWNER REFACTOR S4 (`motion.frameOwner.terminals`, ``TerminalDragTunables/framesOwnedByCommit``), cmux-ad m18:
/// one per window. A terminal whose size changes takes its new bounds at once and asks Ghostty for that size in the same
/// turn (``TerminalSurfaceView/place(_:)``); Ghostty draws it on its renderer thread (the reflow preview re-wraps the text
/// at that size). Just before Core Animation's commit of every main run-loop turn while a request waits (a run-loop
/// observer at ``passOrder``), the presenter's pass asks each waiting terminal for that frame
/// (`ghostty_surface_host_frame`, present true): a drawn one becomes the layer's contents in the commit that carries its
/// bounds. One not drawn yet is a late landing (``Stats/lateLandings``, ``isLate(_:)``): its bounds are already in this
/// commit with the last frame, top-left and not stretched, and the frame shows in the first commit after it is drawn
/// (the watch, each refresh). Nothing keeps an old size (m18 deleted ready-or-keep's keep, its keep limit and the group
/// that held ready frames for a slow neighbour: with no keep every request lands in its first pass, so a group could only
/// delay a ready frame). The main thread never waits for a frame; the present and the geometry go together under
/// `[CATransaction lock]` (Ghostty's call-site rule for `ghostty_surface_host_frame`).
///
/// One refresh after a commit that changed a terminal's shown size, the presenter tells Ghostty that commit is done
/// (`ghostty_surface_host_frame_committed`), so the terminal's echo goes to the screen off the main thread again. A new
/// display scale is the same request: the layer takes the scale with the frame drawn at it, or at the pass anyway
/// (``TerminalSurfaceView/holdsScale(_:)``). The lock span holds only the present and the scale; what follows the new
/// size runs after it (``TerminalSurfaceView/frameDidLand()``).
final class TerminalFramePresenter {
    /// The pass's run-loop order: just before Core Animation's commit (2,000,000), after the turn's other work.
    static let passOrder: CFIndex = 1_999_999
    /// Refreshes a terminal whose bounds changed without a present is watched for its frame.
    static let watchLimit = 240

    /// What the presenters did, cumulative (diagnostics and tests).
    struct Stats: Equatable {
        var passes = 0
        /// Requests whose frame showed with their bounds in one commit.
        var presented = 0
        /// Requests whose new bounds landed before Ghostty drew their frame: the layer shows its last frame (top-left,
        /// not stretched) in them until that frame shows (``TerminalFramePresenter/isLate(_:)``).
        var lateLandings = 0
        var longestPass: Duration = .zero
    }

    /// What this window's presenter did, cumulative.
    private(set) var stats = Stats()

    private struct Request {
        weak var view: TerminalSurfaceView?
    }

    private struct Watch {
        weak var view: TerminalSurfaceView?
        var ticks = 0
        /// Its bounds landed before its frame was drawn: it shows its last frame until the new one shows.
        var late = false
    }

    private weak var window: NSWindow?
    private var requests: [ObjectIdentifier: Request] = [:]
    /// Terminals whose shown size changed outside a present (a first frame, a reveal, a fallback), until their layer
    /// shows the host size.
    private var watched: [ObjectIdentifier: Watch] = [:]
    /// Terminals whose shown size changed in a commit that is done by the next refresh.
    private var commits: [ObjectIdentifier: Watch] = [:]
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

    /// `view` asked Ghostty for a frame at a new size: the next pass presents it with its bounds, or counts it late.
    func request(_ view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        requests[id] = Request(view: view)
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
        lateCounts[id] = nil
    }

    /// Whether `view` waits for a present here.
    func isWaiting(_ view: TerminalSurfaceView) -> Bool { requests[ObjectIdentifier(view)] != nil }

    /// Whether `view`'s bounds landed before Ghostty drew their frame and that frame has not shown yet (counted in
    /// ``Stats/lateLandings`` and ``lateLandings(of:)``).
    func isLate(_ view: TerminalSurfaceView) -> Bool { watched[ObjectIdentifier(view)]?.late == true }

    /// How many times `view`'s bounds landed before their frame was drawn, cumulative (films, bench and tests).
    func lateLandings(of view: TerminalSurfaceView) -> Int { lateCounts[ObjectIdentifier(view)] ?? 0 }

    /// Late landings per terminal (``lateLandings(of:)``); a terminal's entry goes with ``cancel(_:)``.
    private var lateCounts: [ObjectIdentifier: Int] = [:]

    #if DEBUG || CMUX_BENCH_HOOKS
    /// What this presenter holds for `view` (`debug.motion` trace): "request" (a size waits for the pass), "late" (its
    /// bounds landed before its frame was drawn), "watch" (its shown size changed outside a present), "commit" (its
    /// commit is reported at the next refresh), or "-".
    func debugState(of view: TerminalSurfaceView) -> String {
        let id = ObjectIdentifier(view)
        if requests[id] != nil { return "request" }
        if watched[id]?.late == true { return "late" }
        if watched[id] != nil { return "watch" }
        if commits[id] != nil { return "commit" }
        return "-"
    }
    #endif

    // MARK: Frames

    /// One refresh: the commits of earlier passes are done (``commits``), and watched terminals are read.
    private func tick() -> Bool {
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

    /// Before this turn's commit: each waiting terminal shows its frame drawn at its new bounds in this commit, or, not
    /// drawn yet, lands late (its bounds are in this commit already) and is watched until its frame shows. It never
    /// waits and never keeps.
    func pass() { // perf-hot: 1ms motion-frame
        guard !requests.isEmpty else {
            passObserver = nil
            return
        }
        let started = ContinuousClock.now
        stats.passes += 1
        for (id, request) in requests {
            guard let view = request.view else { continue }
            // Ghostty's call-site rule: the present and the layer's geometry under the Core Animation lock, so no
            // off-main commit of another terminal can ship this one's new frame with other geometry in between.
            CATransaction.lock()
            let shown = view.hostFrame(present: true)
            // The layer takes a held scale with its frame, or now (no keep across commits).
            view.applyHeldScale()
            CATransaction.unlock()
            switch shown {
            case GHOSTTY_HOST_FRAME_PRESENTED, GHOSTTY_HOST_FRAME_SHOWN:
                stats.presented += 1
                commits[id] = Watch(view: view)
                // Outside the lock span: what follows the new size and reads Ghostty under the terminal's lock.
                view.frameDidLand()
            case GHOSTTY_HOST_FRAME_NONE:
                // Nothing shown yet: the first frame presents itself and fits these bounds.
                watched[id] = Watch(view: view)
            case GHOSTTY_HOST_FRAME_HIDDEN:
                // Shown again, it is watched again (``TerminalSurfaceView/updateOcclusion()``).
                break
            default:
                // Not drawn yet (or held by synchronized output): the bounds stay, the last frame shows in them, and the
                // watch presents the new frame in the first commit after it is drawn.
                stats.lateLandings += 1
                lateCounts[id, default: 0] += 1
                watched[id] = Watch(view: view, late: true)
                view.frameDidLand()
            }
        }
        requests.removeAll(keepingCapacity: true)
        passObserver = nil
        stats.longestPass = max(stats.longestPass, started.duration(to: .now))
    }
}
