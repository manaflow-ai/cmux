import AppKit
import CmuxNextWakeups
import GhosttyNextKit
import QuartzCore

/// FRAME OWNER REFACTOR S4 (`motion.frameOwner.terminals`, ``TerminalDragTunables/framesOwnedByCommit``): one per
/// window. A terminal whose size changes asks Ghostty for a frame at the new size (``TerminalSurfaceView/place(_:anchor:)``)
/// and keeps its old bounds and old frame. Inside the Core Animation commit of each refresh, after AppKit's layout and
/// display, the presenter's pass asks each waiting terminal for that frame (`ghostty_surface_host_frame`): a drawn one
/// becomes the layer's contents and the view takes the new bounds in that same commit; one not drawn yet keeps both
/// (ready-or-keep). The main thread never waits for a frame. Chromium does the same at a resize: the browser compositor
/// shows a new size only with a frame the renderer submitted for it and keeps the old surface until then.
///
/// Requests of one refresh form a group that presents together for at most ``groupTicks`` refreshes, so two terminals
/// beside one divider land in the same commit. A request kept more than ``keepLimit`` passes takes its bounds anyway
/// (counted in ``Stats/fallbacks``). One refresh after a commit that changed a terminal's shown size, the presenter
/// tells Ghostty that commit is done (`ghostty_surface_host_frame_committed`), so the terminal's echo goes to the screen
/// off the main thread again.
final class TerminalFramePresenter {
    /// Refreshes a group of requests waits for its slowest member.
    static let groupTicks: UInt64 = 2
    /// Passes a request keeps its old size before it takes its bounds without its frame.
    static let keepLimit = 6
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
        var keeps = 0
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
    /// Terminals that landed at a size older than the one they want now: they ask again next refresh.
    private var followUps: [ObjectIdentifier: Watch] = [:]
    private var epoch: UInt64 = 0
    private let passLayer = CommitPassLayer()
    private lazy var client = FrameClient(owner: "Terminal.framePresenter", isAnimation: false, scheduler: { [weak self] in
        self?.window.map(FrameScheduler.forWindow) ?? .app
    }) { [weak self] _ in
        self?.tick() ?? false
    }

    private init(window: NSWindow) {
        self.window = window
        passLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
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
        followUps[id] = nil
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
        followUps[id] = nil
        commits[id] = nil
    }

    /// Whether `view` waits for a present here.
    func isWaiting(_ view: TerminalSurfaceView) -> Bool { requests[ObjectIdentifier(view)] != nil }

    // MARK: Frames

    /// One refresh, outside the commit: the commits of earlier passes are done; watched terminals are read; the
    /// terminals that landed short ask again; the next commit gets a pass while a request waits.
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
                _ = view.hostFrame(present: true)
            default:
                var next = watch
                next.ticks += 1
                watched[id] = next.ticks > Self.watchLimit ? nil : next
            }
        }
        if !followUps.isEmpty {
            let asking = followUps
            followUps.removeAll(keepingCapacity: true)
            for (_, follow) in asking { follow.view?.requestWantedFrame() }
        }
        if !requests.isEmpty { armPass() }
        return !requests.isEmpty || !watched.isEmpty || !commits.isEmpty || !followUps.isEmpty
    }

    /// The pass runs inside the commit of the open transaction (``CommitPassLayer``); outside a layer tree, now.
    private func armPass() {
        guard let host = window?.contentView?.layer else { return pass() }
        passLayer.onDisplay = { [weak self] in self?.pass() }
        if passLayer.superlayer !== host { host.addSublayer(passLayer) }
        passLayer.setNeedsDisplay()
    }

    /// Inside the commit: each waiting terminal shows its frame at the new size with its new bounds, or keeps both.
    /// No allocation per request, no observed state written, no wait.
    func pass() { // perf-hot: 1ms motion-frame
        guard !requests.isEmpty else { return }
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
            var next = request
            if waitingGroups.contains(request.epoch), epoch &- request.epoch < Self.groupTicks {
                if Self.isReady(view.hostFrame(present: false)) { stats.groupWaits += 1 }
                next.keeps += 1
                requests[id] = next
                continue
            }
            let shown = view.hostFrame(present: true)
            switch shown {
            case GHOSTTY_HOST_FRAME_PRESENTED, GHOSTTY_HOST_FRAME_SHOWN:
                stats.presented += 1
                land(view, id: id, watch: false)
            case GHOSTTY_HOST_FRAME_NONE, GHOSTTY_HOST_FRAME_HIDDEN:
                // Nothing to keep: the bounds go now; a frame that comes later fits them.
                land(view, id: id, watch: shown == GHOSTTY_HOST_FRAME_NONE)
            default:
                stats.keeps += 1
                next.keeps += 1
                if next.keeps > Self.keepLimit {
                    stats.fallbacks += 1
                    land(view, id: id, watch: true)
                } else {
                    requests[id] = next
                }
            }
        }
        stats.longestPass = max(stats.longestPass, started.duration(to: .now))
    }

    private func land(_ view: TerminalSurfaceView, id: ObjectIdentifier, watch: Bool) {
        requests[id] = nil
        let followUp = view.landRequestedFrame()
        if watch { watched[id] = Watch(view: view) } else { commits[id] = Watch(view: view) }
        if followUp { followUps[id] = Watch(view: view) }
    }

    private static func isReady(_ state: ghostty_host_frame_e) -> Bool {
        state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_SHOWN
            || state == GHOSTTY_HOST_FRAME_NONE || state == GHOSTTY_HOST_FRAME_HIDDEN
    }
}

/// An empty 1-point layer in the window's tree (drawn nowhere, no actions) that Core Animation displays inside the
/// commit of the open transaction, after AppKit's layout and display and before the encode, as the debug
/// `CommitProbe` does: its display runs the presenter's pass, so what the pass changes ships in that commit, also for
/// a resize made inside AppKit's display cycle. The work is taken by its display: a display Core Animation adds on its
/// own (a new contents scale) runs nothing.
private nonisolated final class CommitPassLayer: CALayer {
    var onDisplay: (@MainActor () -> Void)?

    override func display() {
        let body = onDisplay
        onDisplay = nil
        // The layer joins only window layer trees, from the main actor (`TerminalFramePresenter.armPass`).
        MainActor.assumeIsolated { body?() } // main-proof: Core Animation displays window layers in the main thread's commit
    }

    override func action(forKey event: String) -> (any CAAction)? { nil }
}
