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
/// (``TerminalSurfaceView/drawAhead(_:)``) gives Ghostty that size (a key resize's with its grid to the PTY), so the renderer draws it during the
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
///
/// The program's redraw (RESIZE P0 12, Lawrence m55 "terminals: zero lag"): a resize whose grid went to the program with
/// its size (``request(_:holdTicks:sentEpoch:)``, a key resize) shows its new size only with the frame Ghostty drew after
/// the program's output at that grid (`GHOSTTY_HOST_FRAME_READY_PROGRAM`), for at most `holdTicks` refreshes from the
/// send. Until then the view keeps its old bounds and the program's last frame, as for a frame not drawn yet; at the
/// bound a frame of the size only (`READY`: the program's last picture clipped or padded) shows, so a program that does
/// not redraw never stops the resize. Only a program-drawn screen holds (Ghostty's alternate screen,
/// ``TerminalSurfaceView/programHoldTicks``); a primary-screen terminal shows Ghostty's reflow at the new size in the first
/// frame. Each request has its own bound: a missed one never turns the hold off for later sizes. Ghostty wakes the main run loop when such a frame completes, so the pass that
/// presents it runs at once, not at the next refresh. The divider and the pane chrome never wait: their layout never asks
/// the presenter. Chromium does the same for a renderer's new size: the compositor keeps the old surface until the
/// renderer submits a frame for the new size, then shows it with its bounds.
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
    /// Refreshes from the grid's send a resize's new size waits for the program's redraw at that grid (RESIZE P0 12).
    /// From the refresh the grid went in, not the request's (RESIZE P0 23): a grid the coalescer held to the next refresh
    /// gave the program one refresh less (P0 22, film 034647).
    /// Send -> first presented program frame, cmux21 1x 120 Hz (diag 2b50b18e): px-keys-held p99 11.7 ms, px-keys-single
    /// p99 17.4 ms, about 2 refreshes; 3 covers p99 with one refresh of slack (m55: at most 3 refreshes).
    static let resizeHoldTicks: UInt64 = 3

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
        /// Passes that kept a frame of the size only while the program's redraw at its grid was due (``resizeHoldTicks``).
        var programHolds = 0
        /// Requests with a hold that showed the frame the program drew at their grid.
        var programPresents = 0
        /// Requests with a hold that showed a frame of the size only at the hold's bound (the program did not redraw).
        var boundPresents = 0
        var longestPass: Duration = .zero
    }

    /// What this window's presenter did, cumulative.
    private(set) var stats = Stats()

    private struct Request {
        weak var view: TerminalSurfaceView?
        /// The refresh it was made in: its group.
        var epoch: UInt64
        /// Refreshes from `sentEpoch` a frame of the size only waits for the program's frame at its grid; 0: none.
        var holdTicks: UInt64 = 0
        /// The refresh the request's grid went to the program in, as the request knew it (its size's grid may go later:
        /// ``holdsForProgram(_:of:at:)``).
        var sentEpoch: UInt64 = 0

        /// Whether the pass keeps `view`'s frame in state `state` for the program's redraw in refresh `epoch`. The bound
        /// counts from the refresh the program got the grid in (RESIZE P0 23): while the grid waits in the coalescer's
        /// window (a grid went earlier in its refresh, so it goes at the next one, ``TerminalGridReportCoalescer``) the
        /// program has nothing to redraw at yet; once it goes, its refresh starts the bound. Counted from the request, a
        /// coalesced grid had one refresh less than the bound (RESIZE P0 22, trace of film 034647: 2 of 3).
        func holdsForProgram(_ state: ghostty_host_frame_e, of view: TerminalSurfaceView, at epoch: UInt64) -> Bool {
            guard holdTicks > 0, state == GHOSTTY_HOST_FRAME_READY else { return false }
            if view.gridReports.isWaiting { return true }
            let sent = max(sentEpoch, view.frameOwnership.gridSentEpoch ?? sentEpoch)
            return epoch &- sent < holdTicks
        }
    }

    private struct Watch {
        weak var view: TerminalSurfaceView?
        var ticks = 0
    }

    private struct GridReports {
        weak var coalescer: TerminalGridReportCoalescer?
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
    /// Terminals' grid-report windows that end at a refresh (``TerminalGridReportCoalescer/frameTicked()``).
    private var gridReports: [ObjectIdentifier: GridReports] = [:]
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

    /// The current refresh (a grid's send is stamped with it, ``request(_:holdTicks:sentEpoch:)``).
    var currentEpoch: UInt64 { epoch }

    /// `view` asked Ghostty for a frame at a new size: the next commits present it with its bounds, or keep both.
    /// `holdTicks`: its grid went to the program in refresh `sentEpoch` (now when nil), and a frame of the size only waits
    /// for the program's redraw at that grid until `holdTicks` refreshes after it (``resizeHoldTicks``); 0: no wait.
    func request(_ view: TerminalSurfaceView, holdTicks: UInt64 = 0, sentEpoch: UInt64? = nil) {
        let id = ObjectIdentifier(view)
        requests[id] = Request(view: view, epoch: epoch, holdTicks: holdTicks, sentEpoch: sentEpoch ?? epoch)
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
        watched[id] = nil
        commits[id] = nil
    }

    /// Whether `view` waits for a present here.
    func isWaiting(_ view: TerminalSurfaceView) -> Bool { requests[ObjectIdentifier(view)] != nil }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Tests: called in the pass right after a request's frame became the layer's contents (under nothing: after the lock
    /// span), before this turn's sizes drawn ahead go to Ghostty. What Ghostty drew last is the frame just presented then.
    var presentedHook: ((TerminalSurfaceView) -> Void)?

    /// Tests: called in the pass just before it tries to present a request's frame, with what Ghostty said of it
    /// (READY_PROGRAM: drawn after the program's output at its grid; READY: the size only).
    var presentingHook: ((TerminalSurfaceView, ghostty_host_frame_e) -> Void)?

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
        // A grid-report window ends at this refresh: its newest grid goes (its timer is the backstop).
        for (id, reports) in gridReports where reports.coalescer?.frameTicked() != true {
            gridReports[id] = nil
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
            case GHOSTTY_HOST_FRAME_READY where view.frameOwnership.ahead == nil,
                 GHOSTTY_HOST_FRAME_READY_PROGRAM where view.frameOwnership.ahead == nil:
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
        return !requests.isEmpty || !watched.isEmpty || !commits.isEmpty || !aheads.isEmpty || !gridReports.isEmpty
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
            let state = view.hostFrame(present: false)
            if !Self.isReady(state) || request.holdsForProgram(state, of: view, at: epoch) { waitingGroups.append(request.epoch) }
        }
        for (id, request) in requests {
            guard let view = request.view else {
                requests[id] = nil
                continue
            }
            let age = epoch &- request.epoch
            let state = view.hostFrame(present: false)
            // The program's redraw at the grid that went with this size is due: the old bounds and the program's last frame
            // stay (as for a frame not drawn yet), never the program's last picture clipped or padded at the new size.
            if request.holdsForProgram(state, of: view, at: epoch) {
                stats.programHolds += 1
                continue
            }
            if waitingGroups.contains(request.epoch), age < Self.groupTicks {
                if Self.isReady(state) { stats.groupWaits += 1 }
                continue
            }
            #if DEBUG || CMUX_BENCH_HOOKS
            presentingHook?(view, state)
            #endif
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
                if shown == GHOSTTY_HOST_FRAME_PRESENTED, request.holdTicks > 0 { countHold(state) }
                #if DEBUG || CMUX_BENCH_HOOKS
                presentedHook?(view)
                #endif
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

    /// A held request's frame showed: the program's redraw at its grid, or a frame of the size only at its bound. Each
    /// request has its own bound (RESIZE P0 15): a missed bound does not stop the next size waiting.
    private func countHold(_ state: ghostty_host_frame_e) {
        if state == GHOSTTY_HOST_FRAME_READY_PROGRAM { stats.programPresents += 1 } else { stats.boundPresents += 1 }
    }

    /// After the pass: each spring's next size goes to Ghostty (a key resize's with its grid), so its frame is drawn during the refresh.
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
            if view.frameOwnership.ahead != nil { stats.drawnAhead += 1 }
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
        // A frame that landed late in a spring: the size drawn ahead for the next refresh goes after this pass
        // (``applyAheads()``), not the size wanted now, whose frame could only show a refresh late, and so on for every
        // later frame (review of 5840aea3a603, P1 #1). The next refresh's layout takes the size drawn ahead.
        if followUp, !view.drawsAheadAfterLanding { view.requestWantedFrame() }
    }

    private static func isReady(_ state: ghostty_host_frame_e) -> Bool {
        state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_READY_PROGRAM || state == GHOSTTY_HOST_FRAME_SHOWN
            || state == GHOSTTY_HOST_FRAME_NONE || state == GHOSTTY_HOST_FRAME_HIDDEN
    }
}

extension TerminalFramePresenter: TerminalGridReportTicks {
    /// `coalescer`'s window ends at the next refresh (RESIZE P0 6); it is ticked each refresh until a refresh finds
    /// nothing waiting, which also clears the refresh its last send spent (RESIZE P0 7).
    func tickGridReports(_ coalescer: TerminalGridReportCoalescer) {
        gridReports[ObjectIdentifier(coalescer)] = GridReports(coalescer: coalescer)
        client.activate()
    }
}
