import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import GhosttyNextKit
import QuartzCore

/// FRAME OWNER REFACTOR S4 (cmux-ad m18, m19: no switch, every terminal's frames go through it; m26: draw ahead): one
/// per window. A terminal's bounds change only in the commit that presents a frame drawn at those bounds. The present and
/// the new bounds go together under `[CATransaction lock]` (Ghostty's call-site rule for `ghostty_surface_host_frame`).
/// A terminal whose size changes asks Ghostty for a frame at the new size (``TerminalSurfaceView/place(_:anchor:)``) and
/// keeps its old bounds and old frame. Just before Core Animation's commit of every main run-loop turn while a request
/// waits (a run-loop observer at ``passOrder``), the presenter's pass asks each waiting terminal for that frame
/// (`ghostty_surface_host_frame`): a drawn one becomes the layer's contents and the view takes the new bounds in that
/// same commit; one not drawn yet keeps both (counted in ``Stats/keeps``, and past ``longKeepTicks`` refreshes in
/// ``Stats/longKeeps``, as data: a late frame stays late and is never a main-thread wait, and the bounds never go without
/// their frame, which would stretch or crop it). The pass never draws and never waits.
///
/// In a spring the next refresh's size is known: after the pass, each terminal its pane's spring asked to
/// (``TerminalSurfaceView/drawAhead(_:)``) gives Ghostty that size (render only), so the renderer draws it during the
/// refresh and the next pass presents it with its bounds: no refresh is kept after the spring's first. A divider drag or
/// a Reduce Motion jump has no next size: the last bounds and frame stay until the new frame is drawn. Chromium does the
/// same at a resize: the browser compositor shows a new size only with a frame the renderer submitted for it, keeps the
/// old surface until then, and the renderer gets the size before the compositor needs its frame.
///
/// Requests of one refresh form a group that presents together for at most ``groupTicks`` refreshes, so two terminals
/// beside one divider land in the same commit. One refresh after a commit that changed a terminal's shown size, the
/// presenter tells Ghostty that commit is done (`ghostty_surface_host_frame_committed`), so the terminal's echo goes to
/// the screen off the main thread again. A new display scale is the same request: the layer keeps its scale until the
/// frame drawn at the new one shows (``TerminalSurfaceView/holdsScale(_:)``). The lock span holds only the present and
/// the geometry; what follows the new size runs after it (``TerminalSurfaceView/frameDidLand()``).
final class TerminalFramePresenter {
    /// Refreshes a group of requests waits for its slowest member.
    static let groupTicks: UInt64 = 2
    /// Refreshes a request keeps its old size before its keep counts as long (``Stats/longKeeps``): the 2-refresh
    /// allowance of cmux-ad m18.
    static let longKeepTicks: UInt64 = 2
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
        /// Passes that kept a request longer than ``longKeepTicks`` refreshes (its frame is late; it still keeps).
        var longKeeps = 0
        /// Sizes drawn ahead of a spring's next refresh (``TerminalSurfaceView/applyAhead()``).
        var drawnAhead = 0
        var longestPass: Duration = .zero
    }

    /// What this window's presenter did, cumulative.
    private(set) var stats = Stats()

    /// DIAG (never merge): per-commit trace lines and main-thread call timings, for the T-KEYS root cause.
    var diagLines: [String] = []
    var diagMax: [String: (ms: Double, at: ContinuousClock.Instant)] = [:]
    var diagCounts: [String: Int] = [:]
    func diag(_ line: String) { if diagLines.count < 4000 { diagLines.append("\(Self.diagNow()) \(line)") } }
    func count(_ key: String) { diagCounts[key, default: 0] += 1 }
    func time<T>(_ name: String, _ body: () -> T) -> T {
        let started = ContinuousClock.now
        let value = body()
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if ms > (diagMax[name]?.ms ?? -1) { diagMax[name] = (ms, started) }
        if ms > 4 { diag("SLOW \(name) \(String(format: "%.2f", ms)) ms") }
        return value
    }
    static let diagZero = ContinuousClock.now
    static func diagNow() -> String {
        let d = diagZero.duration(to: .now)
        return String(format: "%.2f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    static func stateName(_ state: ghostty_host_frame_e) -> String {
        switch state {
        case GHOSTTY_HOST_FRAME_NONE: "none"
        case GHOSTTY_HOST_FRAME_HIDDEN: "hidden"
        case GHOSTTY_HOST_FRAME_SHOWN: "shown"
        case GHOSTTY_HOST_FRAME_READY: "ready"
        case GHOSTTY_HOST_FRAME_PRESENTED: "presented"
        case GHOSTTY_HOST_FRAME_PENDING: "pending"
        case GHOSTTY_HOST_FRAME_HELD: "held"
        default: "other"
        }
    }

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
    /// Terminals whose spring's next size goes to Ghostty after this turn's pass (``drawAhead(_:)``); one whose frame
    /// still waits keeps its entry until that frame lands.
    private var aheads: [ObjectIdentifier: Request] = [:]
    /// Terminals whose draw-ahead size went to Ghostty, and the refresh it went in: one that no layout took within 2
    /// refreshes (its spring ended or moved elsewhere) goes back to its bounds' size (``TerminalSurfaceView/dropAhead()``).
    private var applied: [ObjectIdentifier: Request] = [:]
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

    /// `view`'s spring gives it a new size at the next refresh: the size goes to Ghostty after this turn's pass, once this
    /// refresh's frame is presented (``TerminalSurfaceView/applyAhead()``).
    func drawAhead(_ view: TerminalSurfaceView) {
        aheads[ObjectIdentifier(view)] = Request(view: view, epoch: epoch)
        armPass()
        client.activate()
    }

    /// `view` stops owning its frame through this window (another window, hidden).
    func cancel(_ view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        requests[id] = nil
        aheads[id] = nil
        applied[id] = nil
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
        for (id, ahead) in applied {
            guard let view = ahead.view, view.frameOwnership.ahead != nil else {
                applied[id] = nil
                continue
            }
            guard epoch &- ahead.epoch >= 2 else { continue }
            applied[id] = nil
            view.dropAhead()
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
            case GHOSTTY_HOST_FRAME_READY where view.frameOwnership.ahead == nil:
                // Its bounds already have the host size (they were given without a present): the frame fits them. Not a
                // frame drawn ahead: it waits for the bounds of its refresh.
                CATransaction.lock()
                _ = view.hostFrame(present: true)
                CATransaction.unlock()
            default:
                var next = watch
                next.ticks += 1
                watched[id] = next.ticks > Self.watchLimit ? nil : next
            }
        }
        return !requests.isEmpty || !watched.isEmpty || !commits.isEmpty || !applied.isEmpty || !aheads.isEmpty
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
        guard !requests.isEmpty || !aheads.isEmpty else {
            passObserver = nil
            return
        }
        defer { applyAheads() }
        let started = ContinuousClock.now
        stats.passes += 1
        // A group (the requests of one refresh) waits for its slowest member while it is younger than `groupTicks`.
        var waitingGroups: [UInt64] = []
        for (_, request) in requests where !waitingGroups.contains(request.epoch) {
            guard let view = request.view else { continue }
            let st = time("hostFrame.query") { view.hostFrame(present: false) }
            diag("pass req \(view.diagName) epoch \(request.epoch) now \(epoch) inFlight \(view.frameOwnership.inFlight.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-") bounds \(Int(view.bounds.width))x\(Int(view.bounds.height)) aheadHit \(view.diagAheadHit) state \(Self.stateName(st))")
            count("req.\(view.diagAheadHit ? "aheadHit" : "fresh").\(Self.stateName(st))")
            if !Self.isReady(st) { waitingGroups.append(request.epoch) }
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
            time("CATransaction.lock") { CATransaction.lock() }
            let shown = time("hostFrame.present") { view.hostFrame(present: true) }
            diag("present \(view.diagName) -> \(Self.stateName(shown)) drawnGridAtPresent \(view.diagDrawnGrid) inFlight \(view.frameOwnership.inFlight.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")")
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
                // Kept: its bounds and its frame stay as they are (never the bounds alone: that stretches the frame).
                stats.keeps += 1
                if age > Self.longKeepTicks { stats.longKeeps += 1 }
            }
        }
        if requests.isEmpty, aheads.isEmpty { passObserver = nil }
        stats.longestPass = max(stats.longestPass, started.duration(to: .now))
    }

    /// After the pass: each spring's next size goes to Ghostty (render only), so its frame is drawn during the refresh.
    private func applyAheads() { // perf-hot: 1ms motion-frame
        guard !aheads.isEmpty else { return }
        for (id, ahead) in aheads {
            guard let view = ahead.view, view.frameOwnership.pendingAhead != nil else {
                aheads[id] = nil
                continue
            }
            // Its frame of this refresh still waits: the next size goes once that frame lands (a newer one wanted at it
            // would drop the frame).
            guard view.frameOwnership.inFlight == nil else { continue }
            aheads[id] = nil
            view.applyAhead()
            if view.frameOwnership.ahead != nil {
                stats.drawnAhead += 1
                applied[id] = Request(view: view, epoch: epoch)
            }
        }
        if requests.isEmpty, aheads.isEmpty { passObserver = nil }
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
