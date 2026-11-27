public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Supplies the view hosted in each pane. The layout does not know about
/// terminals or browsers; the App returns a view containing the tab strip
/// and the active tab's content.
///
/// Views stay alive and in the hierarchy while scrolled offscreen or on an
/// inactive screen. Use `panePresenceDidChange` (or `LayoutModel.visiblePanes`
/// and `keepAlivePanes`) to pause rendering for occluded panes and to release
/// content of panes far from the viewport.
public protocol LayoutPaneContentProvider: AnyObject {
    /// Creates the view for a pane the first time it appears.
    func makeContentView(for pane: PaneID) -> NSView
    /// Whether this pane's live content keeps its painted size while a split or close springs.
    /// The host clips the held page and lays it out once when the spring lands.
    func holdsContentInMotion(for pane: PaneID) -> Bool
    /// The pane's content goes: torn down now. Called in the update the pane left the layout, or, for a pane a
    /// close retired (``retainContentView(_:for:retired:)``), once the close showed; for a pane a zoom keeps, when the
    /// unzoomed layout no longer has it.
    func releaseContentView(_ view: NSView, for pane: PaneID)
    /// `retired` true: a close took the pane out of the layout in this update, but its host stays until the close
    /// shows and is torn down after that (`LayoutViewContext.retire`): the provider stops counting it as shown now and
    /// keeps its content for ``releaseContentView(_:for:)`` or its return. False: the layout took that host back (a close
    /// taken back before its host went), as if made again. The panes a zoom leaves stay in the layout model and get neither.
    func retainContentView(_ view: NSView, for pane: PaneID, retired: Bool)
    /// The pane scrolled on screen, into the keep-alive band, or away (other
    /// screen, far scroll). Panes start `.hidden`.
    func panePresenceDidChange(_ pane: PaneID, presence: PanePresence)
    /// The pane's content kind for the frame-timing log (`terminal`, `browser`, `agent`, `page`, ...) and whether
    /// its content has presented a picture (a terminal's surface drew, a page's window shows); nil: unknown. Read once
    /// per pane per timed transition, at its first frame (`TransitionFrameLog`, `surface` and `blank_first_frame`).
    func transitionSurface(for pane: PaneID) -> (kind: String, presented: Bool)?
}

extension LayoutPaneContentProvider {
    public func holdsContentInMotion(for pane: PaneID) -> Bool { false }
    public func releaseContentView(_ view: NSView, for pane: PaneID) {}
    public func retainContentView(_ view: NSView, for pane: PaneID, retired: Bool) {}
    public func panePresenceDidChange(_ pane: PaneID, presence: PanePresence) {}
    public func transitionSurface(for pane: PaneID) -> (kind: String, presented: Bool)? { nil }
}

/// Pasteboard type for tab drags the layout accepts through AppKit drag and
/// drop. The pasteboard string is the `TabID` raw value. Put only this type
/// on the pasteboard, or hosted views that accept strings take the drop.
public struct LayoutTabDrag {
    public init() {}
    public static let pasteboardType = NSPasteboard.PasteboardType("com.cmuxterm.next.layout.tab")
}

/// Shared state between the root view and its screen views.
final class LayoutViewContext {
    let model: LayoutModel
    weak var provider: (any LayoutPaneContentProvider)?
    /// The provider's next pane content in a host made ahead, parked hidden in a screen view (``parkSpare(_:in:)``).
    private(set) var spareHost: PaneHostView?
    private(set) var hosts: [PaneID: PaneHostView] = [:]
    /// Panes present in any screen of the current snapshot.
    var livePanes: Set<PaneID> = []
    var requestFrames: () -> Void = {}
    /// Lays a waiting drag's input out now, in the event's turn (``LayoutRootView/applyInputAtEvent()``); false when it
    /// waits for the frame tick.
    var applyInputAtEvent: () -> Bool = { false }
    /// A drag's input landed at its event since the window's last frame tick: the next event waits for the tick.
    var inputLandedSinceTick = false
    /// Whether a divider drag's first event of a display frame lays out at once (``LayoutRootView/inputLandsAtEvent``,
    /// `CMUX_NEXT_DIVIDER_INPUT_AT_EVENT=1`); tests set it per layout.
    var inputLandsAtEvent = LayoutRootView.inputLandsAtEvent
    /// The window's frame tick applies its input now (`LayoutFrameInput`): a screen's presentation and the overlay
    /// sync wait for the frame's one pass, after its springs step.
    var holdsPresentations = false
    /// Pane hosts or dividers moved: the overlay plane follows them.
    var overlayNeedsSync: () -> Void = {}
    /// A user gesture moves the layout (a strip, row or scroll-area pan with the finger down): the root reads
    /// as in layout motion until the motion after it lands (`LayoutRootView.setLayoutInMotion`).
    var userMotionStepped: () -> Void = {}
    /// A user gesture ended with nothing left to spring: the motion it started ends.
    var userMotionEnded: () -> Void = {}
    /// A pane's strip clip changed since the last overlay sync (`PaneHostView.setStripClip`): that sync tells the
    /// window once, with its divider lines, and its Chromium pages re-read their clips (`reportInteractiveRects`).
    var stripClipsChanged = false
    /// Screens whose terminals keep their grids until their panes land (`ScreenContentView.holdsGrids`: nothing sets it now).
    var gridHoldScreens: Set<ScreenID> = [] {
        didSet { if oldValue.isEmpty != gridHoldScreens.isEmpty { gridHoldDidChange(!gridHoldScreens.isEmpty) } }
    }
    /// The first such hold began (true) or the last one ended (false): `LayoutRootView.onTerminalGridHold`.
    var gridHoldDidChange: (Bool) -> Void = { _ in }
    /// The right-click menu of a split's divider (``LayoutRootView/dividerMenu``).
    var dividerMenu: ((SplitID) -> NSMenu?)?
    /// The divider drag's frame timing (``LayoutRootView/frameTiming``).
    var frameTiming: TransitionFrameLog?
    /// The strip scrollbar's fade-out deadline clock.
    let scrollbarClock: any Clock<Duration>
    /// Where the pointer is now, in `window`'s coordinates; nil when it cannot
    /// hover there (the window is not key). Cheap: read on every frame that
    /// moves the layout, with no event at hand, because the layout can move
    /// under a still pointer.
    var hoverPointer: @MainActor (NSWindow) -> NSPoint? = { _ in nil }
    /// Whether the window is on top under the pointer (no other window or
    /// panel covers that point, except pass-through panels). A window server
    /// round trip: asked only when a handle is under the pointer.
    var hoverReachesWindow: @MainActor (NSWindow) -> Bool = { _ in false }
    /// Windows above this one that pass divider hover through: the app's
    /// click-catching panels over page windows (`DividerMouseCatchers`).
    var hoverPassThroughWindows: () -> Set<Int> = { [] }
    /// The last topmost answer and what it was asked for (`hoverReaches`).
    private var topmost: (window: Int, pointer: NSPoint, passThrough: Set<Int>, reaches: Bool)?
    /// The answer held for a live resize of a window (`hoverReaches`): the window, the tracker's count at the ask
    /// (`Motion.liveResizeChanges`: the hold ends when it changes), the answer, and whether the ask came after
    /// ``invalidateHoverTopmost()`` in that resize (the windows of the step were in their places).
    private var heldInResize: (window: Int, changes: Int, reaches: Bool, settled: Bool)?
    /// The count of the resize whose next ask is the settled one (`invalidateHoverTopmost()` ended an answer of it).
    private var settlesAt: Int?

    /// ``hoverReachesWindow``, asked again only when the pointer (in window coordinates), the window or the
    /// pass-through panels changed, or after ``invalidateHoverTopmost()``: a presentation pass under a still pointer
    /// (a pan, a spring) asks the window server nothing.
    ///
    /// In a live resize of `window` (or of its parent) one answer holds until the resize ends: the person holds the
    /// mouse button on the window's own edge and AppKit's resize loop has the pointer. Each step moves the handles
    /// and the catcher panels under the pointer, and each of those asked again: a window server round trip two or
    /// three times in every step of the drag (WINDOW RESIZE 2). The held answer can differ from the window server's
    /// until the resize ends (a window of another app that the edge moves under, a dialog that opens): the first ask
    /// after the end goes to the window server again.
    ///
    /// Which answer holds: the first ask of a drag comes from the layout pass of its first step, before the page
    /// windows and the catcher panels of that step are in their places, so it can meet a window that is on top
    /// there only until the step ends. The first ``invalidateHoverTopmost()`` of the resize (the catcher sync of that
    /// step) ends that answer, and the ask that follows is the one that holds. So a drag asks two times at most.
    ///
    /// The hold ends by the tracker's count (`Motion.liveResizeChanges`), not by a view callback: a full screen
    /// transition counts as a live resize (`Motion.isLiveResizing`) and ends with no `viewDidEndLiveResize`, and a
    /// second resize can start with no ask after the first (no handle under the pointer then).
    ///
    /// Where an overlay of the window takes the mouse (a toast over a divider), nothing is asked: the window is not on
    /// top there, though the window server's answer for the window may still be the window itself (the overlay panel
    /// takes the pointer one move late) and the answer held for a still pointer was from before the overlay came.
    func hoverReaches(_ window: NSWindow, pointer: NSPoint) -> Bool { // perf-hot: 1ms window-resize-step
        if WindowOverlayHost.overlayTakesMouse(in: window, atWindowPoint: pointer) { return false }
        guard !Motion.isLiveResizing(window) else {
            let changes = Motion.liveResizeChanges
            if let heldInResize, heldInResize.window == window.windowNumber, heldInResize.changes == changes {
                return heldInResize.reaches
            }
            let reaches = hoverReachesWindow(window)
            heldInResize = (window.windowNumber, changes, reaches, settlesAt == changes)
            settlesAt = nil
            return reaches
        }
        settlesAt = nil
        heldInResize = nil
        let passThrough = hoverPassThroughWindows()
        if let topmost, topmost.window == window.windowNumber, topmost.pointer == pointer, topmost.passThrough == passThrough {
            return topmost.reaches
        }
        let reaches = hoverReachesWindow(window)
        topmost = (window.windowNumber, pointer, passThrough, reaches)
        return reaches
    }

    /// The windows over the pointer may have changed (a key change, a panel shown or moved, a tracking event).
    /// In a live resize this ends the held answer one time only, when that answer is from before the first call
    /// (`hoverReaches`): the later steps of the drag ask the window server nothing.
    func invalidateHoverTopmost() {
        topmost = nil
        if let held = heldInResize, !held.settled {
            heldInResize = nil
            settlesAt = held.changes
        }
    }

    init(model: LayoutModel, provider: any LayoutPaneContentProvider, scrollbarClock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        self.provider = provider
        self.scrollbarClock = scrollbarClock
        // The shared pointer source (`PointerHover`, CmuxNextDesign): the
        // real pointer while the window is key and visible, `debug.mouse`'s
        // synthesized pointer in DEBUG builds (it also passes the topmost check).
        hoverPointer = { window in PointerHover.pointer(in: window, requireKey: true) }
        hoverReachesWindow = { [weak self] window in
            PointerHover.isTopmost(window, passThrough: self?.hoverPassThroughWindows() ?? [])
        }
    }

    var style: LayoutStyle { model.style }

    /// Pins Reduce Motion for this view only (tests), instead of the
    /// process-wide `Motion.reduceMotionOverride`, which leaks into every
    /// test that runs while an async test is suspended.
    var reduceMotionOverride: Bool?

    /// The window that shows this layout (its root view's): a live resize or a full screen
    /// transition of it snaps the layout's movement; another window's does not.
    var window: () -> NSWindow? = { nil }

    /// Movement snaps: Reduce Motion, `ui.animationSpeed` "off" or a live resize of the layout's window (`Motion`).
    var reduceMotion: Bool { reduceMotionOverride ?? !Motion.panes.animatesMovement(in: window()) }

    /// `ui.paneAnimations` (on by default; plans/cmux-next/motion.md rule 9): with it off, a ratio or width change that
    /// is no explicit equalize, a released divider and a camera's reveal snap. A split, a close, a zoom and an unzoom
    /// show in one frame with it on or off. A test that pins `reduceMotionOverride` pins this too.
    var animatesPaneLayout: Bool { reduceMotionOverride.map { !$0 } ?? Motion.panes.animatesPaneLayout(in: window()) }

    /// Asks for the panes' move at a split, a close and a zoom in a test that pins `reduceMotionOverride`
    /// (``movesPanesAtCommit``); nil: the pin alone gives none.
    var commitMotionOverride: Bool?

    /// Whether a split, a close and a zoom move their panes (``PaneCommitMotion``): movement animates and
    /// `ui.paneAnimations` is on. A test that pins `reduceMotionOverride` gets no move unless it asks for one, so a
    /// fixture that counts the frames of a change that shows in one commit keeps its count.
    var movesPanesAtCommit: Bool { !reduceMotion && (commitMotionOverride ?? (reduceMotionOverride == nil && animatesPaneLayout)) }

    /// `pane`'s host: the one it has, the one a change kept for it, or a new one. A host that comes back hidden (a pane
    /// a zoom covered) stays hidden: its screen shows it in the pass that places it
    /// (`ScreenContentView.showSnapReturning`), never a frame earlier at the place it had.
    func host(for pane: PaneID) -> PaneHostView {
        if let host = hosts[pane] { return host }
        // A close is taken back before its host went (a refused close, a reopen), or an unzoom brings back a pane the
        // zoom covered: the same host shows again.
        if let entry = retired.removeValue(forKey: pane) {
            // Before it shows again, in this turn: a release held for it ran after its new content, and took it (base order).
            runClosingWork(of: pane, now: true)
            entry.host.isLeaving = false
            entry.host.chrome.isHidden = entry.host.hidesRing // a move still keeps it under the others: no ring in this turn
            // Its ring is placed again by the next overlay sync, whatever it last showed.
            entry.host.overlaySyncKey = nil
            hosts[pane] = entry.host
            if entry.until == .landing { provider?.retainContentView(entry.host.content, for: pane, retired: false) }
            return entry.host
        }
        // A probe's time of the make of a pane's content while `debug.motion` records (with views made ahead or with none).
        MotionTrace.begin("layout.content")
        let content = provider?.makeContentView(for: pane) ?? NSView()
        MotionTrace.end("layout.content")
        // The provider handed the content made ahead: its host, parked in the window, takes the pane (no window walk now).
        if let spare = spareHost, spare.content === content {
            spareHost = nil
            spare.adopt(pane) { [weak self] in self?.provider?.holdsContentInMotion(for: pane) ?? false }
            spare.isHidden = false
            hosts[pane] = spare
            return spare
        }
        let host = PaneHostView(pane: pane, content: content) { [weak self] in
            self?.provider?.holdsContentInMotion(for: pane) ?? false
        }
        hosts[pane] = host
        return host
    }

    func release(_ pane: PaneID) {
        guard let host = hosts.removeValue(forKey: pane) else { return }
        tearDown(host)
    }

    private func tearDown(_ host: PaneHostView) {
        host.removeFromSuperview()
        host.chrome.removeFromSuperview()
        provider?.releaseContentView(host.content, for: host.pane)
    }

    /// Hosts of panes a close took out of the layout (`ScreenContentView.reconcile`), by the screen that showed them:
    /// shown until the close shows, hidden in the pass that shows it (a page window orders out with the hide,
    /// `CEFHostView.viewDidHide`), and torn down after that (`releaseRetired`). The teardown (the host's layers leaving
    /// the tree, the content released to the provider: its pane controller and a terminal's surface going) is work no
    /// frame shows; done in the frame that showed a close it added to that frame's main turn and Core Animation commit,
    /// which missed refreshes (RESIZE VIDEOS F1).
    /// A zoom keeps the panes it leaves the same way, until the screen unzooms (`Retirement.zoom`): they come back
    /// with the unzoom as they were (RESIZE VIDEOS Z1: the zoom tore down every other pane, 11 pane controllers in
    /// one frame of 42 ms, and the unzoom made them all again in one frame of 48 ms).
    /// `shown`: a layout change took the pane out and has not shown yet (`ScreenContentView+SnapFrame`): the host shows
    /// as it was until that change shows (``hideRetiredShown(of:)``), and is not torn down before.
    private(set) var retired: [PaneID: (host: PaneHostView, screen: ScreenID, until: Retirement, shown: Bool)] = [:]
    /// Work that waits for a closing pane to go (``afterClosing(_:id:_:)``), by pane and id.
    private var closingWork: [PaneID: [String: @MainActor () -> Void]] = [:]
    /// Runs work once the current main run-loop pass committed its frame (`AfterFrameCommit`); a test collects it and runs it.
    var afterCommit: (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) }

    /// Until when a retired host is kept.
    enum Retirement {
        /// A close: until the frame that shows the close is committed.
        case landing
        /// A zoom's covered pane: until its screen unzooms (it comes back then, or is torn down).
        case zoom
    }

    /// Takes `pane`'s host out of the layout without tearing it down; it is released at `until`. The layout change
    /// that takes the pane out has not shown yet: the host and its ring stay as they show, with no clicks, until it
    /// does (``hideRetiredShown(of:)`` hides them then: no hit, no focus, no AX, and a hidden terminal stops drawing),
    /// so no frame shows the old layout without this pane. The stacking order changes in the pass that hides them, so
    /// they keep their rank until then. A pane with no host does nothing.
    func retire(_ pane: PaneID, from screen: ScreenID, until: Retirement) {
        guard let host = hosts.removeValue(forKey: pane) else { return }
        host.isLeaving = true
        retired[pane] = (host, screen, until, true)
        // A close took it out of the layout now: the provider's shown panes lose it in this update, only its teardown
        // waits. A zoom's covered pane is still in the layout (its focus topology, theme, suspend): the provider keeps it.
        if until == .landing { provider?.retainContentView(host.content, for: pane, retired: true) }
    }

    /// Tears down the hosts `screen` retired until `until` (a close's: the frame that showed the close is committed;
    /// a zoom's: it unzoomed and they did not come back), or every one with nil (the screen went away).
    /// A host its change has not shown yet (`shown`) stays, except when the screen goes.
    func releaseRetired(of screen: ScreenID, until: Retirement? = .landing) {
        func goes(_ entry: (host: PaneHostView, screen: ScreenID, until: Retirement, shown: Bool)) -> Bool {
            entry.screen == screen && (until == nil || (entry.until == until && !entry.shown))
        }
        guard retired.values.contains(where: goes) else { return }
        for (pane, entry) in retired where goes(entry) {
            retired[pane] = nil
            tearDown(entry.host)
            runClosingWork(of: pane)
        }
    }

    /// The panes `screen` took out of its layout that still show (``retire(_:from:until:)``): until the change that took
    /// them out shows, or, when that change moves its panes, under the panes that take their room until the motion's end
    /// (`PaneCommitMotion.keepsDeparted`). O(retired panes).
    func retiredShown(of screen: ScreenID) -> [PaneID] {
        retired.compactMap { pane, entry in entry.screen == screen && entry.shown ? pane : nil }
    }

    /// The layout change that took them out shows in this turn: the hosts `screen` kept shown for it
    /// (``retire(_:from:until:)``) hide, their rings with them. Their teardown is work no frame
    /// shows: it follows that frame's commit (``releaseRetired(of:until:)``). Returns whether any hid.
    @discardableResult
    func hideRetiredShown(of screen: ScreenID) -> Bool {
        // A probe's time of this loop while `debug.motion` records (one hide for each pane that the change took out).
        MotionTrace.begin("layout.hide")
        defer { MotionTrace.end("layout.hide") }
        var hid = false
        for (pane, entry) in retired where entry.screen == screen && entry.shown {
            entry.host.isLeaving = false
            entry.host.isHidden = true
            entry.host.chrome.isHidden = true
            retired[pane]?.shown = false
            hid = true
        }
        return hid
    }

    /// The presentation that shows an unzoom placed its panes: each host of `panes` that `screen` holds hidden shows
    /// (the panes that the zoom covered come back). Returns whether any did.
    func showReturning(_ panes: [PaneID], on screen: NSView) -> Bool {
        // A probe's time of this loop while `debug.motion` records (one show for each pane that comes back).
        MotionTrace.begin("layout.show")
        defer { MotionTrace.end("layout.show") }
        var shown = false
        for pane in panes {
            guard let host = hosts[pane], host.superview === screen, host.isHidden else { continue }
            host.isHidden = false
            shown = true
        }
        return shown
    }

    /// Whether `pane` left the layout in a close whose host has not gone yet: it waits for the close to show, or,
    /// hidden, for the commit of the frame that showed it.
    func isClosing(_ pane: PaneID) -> Bool {
        if case .landing? = retired[pane]?.until { return true }
        return false
    }

    /// Holds `work` until closing `pane` goes (the frame that showed its close is committed, or its screen goes) or
    /// comes back, then runs it after that frame's commit; false (nothing held) when `pane` is not closing. A second
    /// `id` replaces the first. The teardown of what a closing pane showed is work no frame shows (RESIZE VIDEOS F1):
    /// in a frame of the close it missed refreshes, so it follows that frame, as Chrome keeps its UI thread to what the
    /// next frame shows.
    func afterClosing(_ pane: PaneID, id: String, _ work: @escaping @MainActor () -> Void) -> Bool {
        guard isClosing(pane) else { return false }
        closingWork[pane, default: [:]][id] = work
        return true
    }

    /// `now`: the pane comes back and the work runs before it shows again; else after this frame's commit.
    private func runClosingWork(of pane: PaneID, now: Bool = false) {
        guard let work = closingWork.removeValue(forKey: pane) else { return }
        if now { for item in work.values { item() } } else { afterCommit { for item in work.values { item() } } }
    }

    /// Whether `chrome` is the ring of a retired host: the overlay sync leaves it for the teardown.
    func isRetiredChrome(_ chrome: NSView) -> Bool { retired.values.contains { $0.host.chrome === chrome } }
}

extension LayoutViewContext {
    /// Puts `content` (the provider's next pane content) in a host made now and parks it hidden in `screen`, the screen
    /// view a new pane most likely shows in: a later ``host(for:)`` whose content is `content` adopts that host, and the
    /// screen's reconcile only unhides it (no move between superviews, no window walk). Nil drops the one parked.
    /// A hidden host in a screen's subviews is a state the screen already has (a closed pane's retired host).
    /// TERMINAL CREATE COST item 4: a New Column's new host and pane entering the window cost 2 ms of the key's turn.
    func parkSpare(_ content: NSView?, in screen: NSView?) {
        spareHost?.removeFromSuperview()
        spareHost = content.flatMap { content in
            guard let screen else { return nil }
            let host = PaneHostView(pane: PaneID(rawValue: "spare-pane-host"), content: content)
            host.isHidden = true
            screen.addSubview(host, positioned: .below, relativeTo: nil)
            return host
        }
    }
}
