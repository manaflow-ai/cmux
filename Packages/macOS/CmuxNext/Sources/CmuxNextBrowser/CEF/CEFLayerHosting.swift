import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import os

/// Layer hosting (fork API 26) of the page window over one ``CEFHostView``:
/// asks the fork for the page window's Core Animation context and shows it in
/// a ``CEFHostedPageView`` at the bottom of the host view. Every page is hosted
/// (no switch since 2026-11-06).
///
/// The context belongs to the page window, not to a tab: every tab of a pane
/// shares it, so a tab switch inside a hosted pane makes no fork call. A new
/// page window (``pageWindowCreated(browser:fork:)``) drops the old context.
///
/// A request made inside Chromium's creation stack (`OnAfterCreated`, the
/// DevTools opened event) can find no page window yet: Chromium adds the
/// WebContents to its window later in that stack. So a new page window's
/// request runs at the end of the run-loop turn, after the stack returned.
/// When the fork still refuses, the next read of the host view by the fork's
/// tracker (``trackerDidRead()``, proof that the tracker is attached) retries
/// once; another refusal waits for the next show.
///
/// A resize never holds the process's commit for Chromium's frame at the new
/// size: the main thread never waits for a page (the resize wait deadlines are
/// 0; tests pass others through the init seams).
///
/// `browser` must name a live browser of the page window: a show records the
/// shown one, and ``windowBrowsersChanged(_:)`` moves it off a closed one.
///
/// Tests drive it through ``Fork`` and the `schedule` seam, without Chromium.
final class CEFLayerHosting {
    /// The fork's layer hosting call: a seam, so tests run this state machine
    /// without Chromium.
    struct Fork {
        /// `cmux_shim_browser_set_layer_hosting`: the page window's context
        /// id (> 0) for `enabled`, 0 when off or refused.
        let setLayerHosting: (_ browser: Int32, _ enabled: Bool) -> UInt32
        /// `cmux_shim_browser_set_resize_sync` (fork API 27): how long a
        /// resize of the page window may hold the commit for Chromium's frame
        /// at the new size, in ms; 0 never holds it. True when the fork took it
        /// (false for a closed browser's id). Nil below API 27, where Chromium
        /// holds it up to 500 ms on every resize.
        let setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)?
        /// `cmux_shim_browser_set_detached_hosting` (fork API 30): the hosted page's window leaves the parent window
        /// and turns headless (`enabled`), or comes back as a child window. True when the fork took it. Nil below
        /// API 30.
        let setDetachedHosting: ((_ browser: Int32, _ enabled: Bool) -> Bool)?

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32,
             setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)? = nil,
             setDetachedHosting: ((_ browser: Int32, _ enabled: Bool) -> Bool)? = nil) {
            self.setLayerHosting = setLayerHosting
            self.setResizeSync = setResizeSync
            self.setDetachedHosting = setDetachedHosting
        }

        /// The shim's call; nil without a shim or below fork API 26, where
        /// nothing changes and showing a tab costs nothing here.
        init?(shim: CEFShimLibrary?, apiVersion: Int32) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
            setResizeSync = apiVersion >= CEFLayerHosting.resizeSyncForkAPI
                ? { browser, timeout in shim.browserSetResizeSync(browser, timeout) == 1 } : nil
            setDetachedHosting = apiVersion >= CEFLayerHosting.detachedForkAPI
                ? shim.browserSetDetachedHosting.map { call in { browser, enabled in call(browser, enabled ? 1 : 0) == 1 } } : nil
        }
    }

    private enum Pending: Equatable {
        case none
        /// A request runs at the end of this run-loop turn (`retry`: it is
        /// the one retry after a refusal).
        case scheduled(retry: Bool)
        /// The fork refused; the tracker's next read schedules the retry.
        case armed
    }

    /// The first fork API with `cmux_browser_set_layer_hosting`.
    static let forkAPI: Int32 = 26
    /// The first fork API with `cmux_browser_set_resize_sync`.
    static let resizeSyncForkAPI: Int32 = 27
    /// The first fork API with `cmux_browser_set_detached_hosting`.
    static let detachedForkAPI: Int32 = 30

    weak var view: NSView?
    /// The page's pixels in this window's layer tree; nil while the page
    /// draws in its own window.
    private(set) var page: CEFHostedPageView?
    /// Where the page window has a hole in the web contents (`CEFTab.applyOcclusion`): the New Tab page, a blank page.
    /// The hosted page shows no pixels there either, as the page window does not (cmux-ad m37: with layer hosting the
    /// New Tab page showed Chromium's opaque page color instead of the window backdrop).
    var pageHole: CEFPageHole = .none {
        didSet { if pageHole != oldValue { page?.hole = pageHole } }
    }
    /// Requests the fork refused, or hosted contexts no `CALayerHost` could
    /// show (`CEFTrackerStats.hostingRefused` sums every view).
    private(set) var refusals = 0
    /// Calls into the fork so far.
    private(set) var forkCalls = 0
    /// A browser of the page window (any tab of it names the same window).
    private(set) var browser: Int32?
    private var fork: Fork?
    private var pending = Pending.none
    private let isEnabled: () -> Bool
    private let schedule: Scheduler
    private let makePage: (CGRect) -> CEFHostedPageView
    private let resizeDeadlineMs: () -> Int32
    private let liveResizeDeadlineMs: () -> Int32
    private let dragResizeDeadlineMs: () -> Int32
    private let refreshIntervals: () -> [Double]
    /// The resize deadline the fork has for this page window: 0, the fork's default, until
    /// ``syncDeadline()`` gives another.
    private var appliedDeadlineMs: Int32 = 0
    /// The window is in a live resize (``windowLiveResize(active:)``).
    private var inLiveResize = false
    /// Tab containers that told a resize-sync drag of the view's pane and have not told its end
    /// (``paneResizeDrag(active:)``): every tab of a pane shares this page window.
    private(set) var paneDragHolders = 0
    /// A person drags the view's pane in resize sync.
    var inPaneDrag: Bool { paneDragHolders > 0 }

    /// Runs a block later on the main actor.
    typealias Scheduler = (_ block: @escaping @MainActor @Sendable () -> Void) -> Void
    /// Runs a block after this run-loop pass's frame commit (``AfterFrameCommit``); tests run it when they choose.
    private let afterCommit: Scheduler
    /// Runs a block once the window's next display frame came (a ``FrameClient`` tick on the view's window), after
    /// that pass's commit; nil uses the view's ``FrameScheduler``. Tests run it when they choose.
    private let afterFrameShown: Scheduler?
    /// The one-tick client of ``afterFrameShown`` while it waits.
    private var shownFrame: FrameClient?

    /// A page shown in this turn whose input window was out of the window (``pageAppeared(windowInWindow:then:)``).
    enum FirstFrameHold: Equatable {
        case none
        /// Detached until the frame it showed in came: its pixels show from the hosted context and no window is ordered.
        case detached
        /// Attached after that frame: the fork orders the window in at its next run-loop observer, so a focus grant
        /// waits until after that.
        case attaching
    }

    /// Where a page shown in this turn is on its way back into the window.
    private(set) var firstFrameHold = FirstFrameHold.none
    /// What runs once that page's window is in (its kept focus ask).
    private var afterFirstFrame: (@MainActor () -> Void)?
    /// That ask after the fork refused the hold's attach: the attach that brings the window in grants it.
    private var owedGrant: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - isEnabled: whether hosting is wanted; always by default (tests pass their own).
    ///   - schedule: runs a block at the end of this run-loop turn; tests run it when they choose.
    ///   - makePage: the hosted view for a frame; tests pass one whose layer host fails.
    ///   - resizeDeadlineMs: the upper bound of a hosted page's resize wait; 0 (never) by default.
    ///   - refreshIntervals: the shortest frame interval of each display, which cap the wait
    ///     (``CEFResizeSyncDeadline``); tests pass fixed rates.
    init(isEnabled: @escaping () -> Bool = { true },
         schedule: @escaping Scheduler = { CEFLayerHosting.atEndOfTurn($0) },
         makePage: @escaping (CGRect) -> CEFHostedPageView = { CEFHostedPageView(frame: $0) },
         resizeDeadlineMs: @escaping () -> Int32 = { 0 },
         liveResizeDeadlineMs: @escaping () -> Int32 = { 0 },
         dragResizeDeadlineMs: @escaping () -> Int32 = { 0 },
         refreshIntervals: @escaping () -> [Double] = { NSScreen.screens.map(\.minimumRefreshInterval) },
         holdsFocus: (() -> Bool)? = nil,
         afterCommit: @escaping Scheduler = { AfterFrameCommit().run($0) },
         afterFrameShown: Scheduler? = nil) {
        self.holdsFocus = holdsFocus ?? { false }
        self.afterCommit = afterCommit
        self.afterFrameShown = afterFrameShown
        self.isEnabled = isEnabled
        self.resizeDeadlineMs = resizeDeadlineMs
        self.liveResizeDeadlineMs = liveResizeDeadlineMs
        self.dragResizeDeadlineMs = dragResizeDeadlineMs
        self.refreshIntervals = refreshIntervals
        self.schedule = schedule
        self.makePage = makePage
        if holdsFocus == nil { self.holdsFocus = { [weak self] in Self.pageWindowIsKey(over: self?.view) } }
    }

    /// Whether a refused request waits for the tracker's next read.
    var isRetryArmed: Bool { pending == .armed }

    /// A new page window over the view (a pane's Chromium window, or a docked
    /// DevTools): the old window's context went with it. Called inside
    /// Chromium's creation stack, so the request waits for the end of the turn.
    func pageWindowCreated(browser: Int32, fork: Fork?) {
        dropPage()
        self.browser = browser
        self.fork = fork
        // A new page window starts with the fork's default: it never holds the commit.
        appliedDeadlineMs = 0
        pending = .none
        // The window may be in a live resize already.
        syncDeadline()
        guard fork != nil, isEnabled() else { return }
        request(retry: false)
    }

    /// A tab of the page window shows (`CEFPaneHost.present`). While the page
    /// is hosted and hosting is still wanted, nothing reaches the fork unless
    /// the resize deadline changed; a tunable change applies here.
    func pageShown(browser: Int32) { // perf-hot: 10ms tab-switch (every Chromium tab show)
        guard let fork else { return }
        self.browser = browser
        if attachOwed { attachIfOwed() }
        // A tab of a page window left detached at rest shows: the person is about to use it.
        if isDetached, !attachOwed, !inResizeMotion, firstFrameHold == .none { _ = reattachLeftover(.show) }
        let wanted = isEnabled()
        if wanted == (page != nil) {
            syncDeadline()
            return
        }
        if wanted {
            if case .scheduled = pending { return }
            pending = .none
            apply(fork, browser: browser, retry: false)
        } else {
            pending = .none
            forkCalls += 1
            _ = fork.setLayerHosting(browser, false)
            dropPage()
            syncDeadline()
        }
    }

    /// A display was added, removed or changed its rate (`CEFRuntime`'s one app-wide observer of
    /// `NSApplication.didChangeScreenParametersNotification` calls every host view's): the cap may differ.
    func displaysChanged() {
        displayIntervals = nil
        syncDeadline()
    }

    /// Every display's shortest frame interval, read once and again only after a display change
    /// (``displaysChanged()``): a tab show reads no display list (HOT PATH AUDIT frames, tab-switch).
    private var displayIntervals: [Double]?

    private func shortestIntervals() -> [Double] {
        if let displayIntervals { return displayIntervals }
        let read = refreshIntervals()
        displayIntervals = read
        return read
    }

    /// The host view moved to another window (`CEFHostView.viewDidMoveToWindow`):
    /// a tunable edit made while it was out of every window applies now. Leaving
    /// a window makes no fork call: the cap is every display's, not the window's.
    /// The new window's live resize state replaces the old one: AppKit tells only
    /// the views in a window when its live resize starts and ends.
    func windowDidChange() {
        let wasInMotion = inResizeMotion
        inLiveResize = view?.window?.inLiveResize ?? false
        if isDetached {
            // The old window never ends a live resize or a drag for a view that left it, and a detached page takes no
            // input: it attaches at once, at its new place, and stays attached for the rest of the motion.
            attach()
            motionKeepsAttached = inResizeMotion
        } else if wasInMotion, !inResizeMotion {
            motionKeepsAttached = false
        }
        guard view?.window != nil else { return }
        syncDeadline()
    }

    /// The page window's tabs changed (`CEFPaneHost.removed`): when the recorded
    /// browser is not one of `browsers` any more (a popup host's placeholder, the
    /// last shown tab closed), a live one names the window from now on, so a
    /// later deadline reaches the fork.
    func windowBrowsersChanged(_ browsers: [Int32]) {
        guard let browser, !browsers.contains(browser) else { return }
        self.browser = browsers.first
        if attachOwed { attachIfOwed() }
    }

    /// The window starts or ends a live resize (`CEFHostView.viewWillStartLiveResize`). Fork API 27 never lets a page
    /// window hold the window's commit unless asked, so for the live resize every page over the view, hosted or not,
    /// waits up to `liveResizeDeadlineMs` (capped like every deadline, ``CEFResizeSyncDeadline``) for its frame at the
    /// new size (Chromium waited up to 500 ms there); after it a hosted page goes back to its pane deadline and a page
    /// window to none.
    func windowLiveResize(active: Bool) {
        guard active != inLiveResize else { return }
        let was = inResizeMotion
        inLiveResize = active
        syncDeadline()
        if inResizeMotion != was { motionChanged() }
    }

    /// A person's divider or edge drag of the view's pane began (`true`) or its release landed (`false`), with
    /// `browserResize.dragResize` at `resizeSync` (`CEFTabContentView.paneResizeGestureDidChange`), or with S5 on
    /// (`motion.frameOwner.pages`) a drag or a key resize's spring (`CEFTabContentView+PageSync`). Every frame of the
    /// drag and of its release's spring resizes the page window, so for that time every page over the view, hosted or
    /// not, waits up to `dragResizeDeadlineMs` (capped at half the shortest display frame, ``CEFResizeSyncDeadline``,
    /// so the app's frame still commits by its display link's target time) for its frame at the pane's new size, and
    /// shows it in the same frame as its pane. After it a hosted page goes back to its pane deadline and a page
    /// window to none. Below fork API 27 nothing reaches the fork: the page lays out live.
    ///
    /// Each tab container of the pane tells its own start and end (a parked container leaves early, the shown one
    /// lands), so the drag lasts until the last of them ended; an end with no start is ignored.
    func paneResizeDrag(active: Bool) {
        let wasDragging = inPaneDrag
        paneDragHolders = active ? paneDragHolders + 1 : max(0, paneDragHolders - 1)
        guard inPaneDrag != wasDragging else { return }
        syncDeadline()
    }

    /// The fork's tracker read the host view (`-cmuxClipPath`): it is attached
    /// to the page window now, so a refused request may succeed.
    func trackerDidRead() { // perf-hot: 1us cef-geometry (each tracker read)
        if attachOwed { attachIfOwed() }
        guard pending == .armed else { return }
        request(retry: true)
    }

    // MARK: Detached in a resize motion (fork API 30)

    /// The hosted page's window is headless and off screen (``cmux_browser_set_detached_hosting``): a resize of the
    /// view moves no window. Only during a resize motion of the view (``resizeMotion(active:)``, a window live resize).
    private(set) var isDetached = false
    /// Resize motions of the view that have begun and not ended: a person's divider drag of its pane, told by each tab
    /// container of the pane (``CEFTabContentView``). A key resize keeps the page attached (``CEFTabContentView/holdPage(for:)``).
    private(set) var motionHolders = 0
    /// The page held the keys when this motion began, so it stays a page window through it: detaching the key window
    /// would order it out and move the keys (an AppKit key change, the #24913 stall class). Decided once a motion.
    private var motionKeepsAttached = false
    /// Whether the page holds the keyboard (its window is key, or a focus ask waits for it). The page's own window
    /// being key by default; ``CEFPaneHost`` adds its shown tab's waiting ask.
    var holdsFocus: () -> Bool

    /// A motion ended and the fork refused to bring the page window back (a busy fork, or a browser that went with a
    /// renderer restart): the page still shows its pixels in the layer tree but its window is headless and off screen,
    /// so it takes no click. Nothing else ends a motion, so the attach is retried at the next show, browser change,
    /// window change and tracker read (``attachIfOwed()``) until the fork takes it.
    private(set) var attachOwed = false

    /// The view is in a resize motion: a live resize of its window or a motion of its pane.
    var inResizeMotion: Bool { inLiveResize || motionHolders > 0 }

    /// A resize motion of the view's pane began (`true`) or landed (`false`): a person's divider drag, from the press
    /// to the landing (a key resize keeps the page attached, RESIZE P0 5). Every frame of it resizes or moves the
    /// page, so for its length a hosted page that does not hold the keys is detached: its window leaves the parent
    /// window and turns headless, and the fork's per-frame tracker update records the frame in the process with no
    /// WindowServer `setFrame`, child-window order, mask or mouse routing. The page still lays out at every size.
    /// At the landing the page window comes back once, at the final size. An end with no start is ignored.
    func resizeMotion(active: Bool) { // perf-hot: 1ms resize-motion (motion start and landing)
        let was = inResizeMotion
        motionHolders = active ? motionHolders + 1 : max(0, motionHolders - 1)
        guard inResizeMotion != was else { return }
        motionChanged()
    }

    /// The page takes the keys during a motion (a focus shortcut mid-drag): its window comes back now, so the grant
    /// that follows makes a page window key as before, and the page stays attached for the rest of the motion.
    /// - Returns: Whether the page window was detached and came back now (its grant then waits for the next commit).
    /// At rest (no motion, no first-frame hold) a page that is still detached is a leftover whose attach never came:
    /// it comes back now (``reattachLeftover(_:)``), so the grant that follows reaches a page window again.
    @discardableResult
    func pageTakesFocus() -> Bool {
        guard inResizeMotion else {
            // Attached in this turn by a press: the window is a child again only after the next commit.
            if reattachedAwaitingCommit { return true }
            return firstFrameHold == .none && isDetached && !attachOwed && reattachLeftover(.focus)
        }
        motionKeepsAttached = true
        return isDetached && setDetached(false)
    }

    // MARK: A page the person reaches is never left detached

    /// What found a detached page at rest (the `cef-hosting` log line names it).
    enum LeftoverReach: String {
        /// A press or a scroll wheel event on the page area (``CEFHostView``).
        case pointer
        /// A focus grant (``pageTakesFocus()``).
        case focus
        /// A show of one of the page window's tabs (``pageShown(browser:)``).
        case show
    }

    /// The person pressed or scrolled on the page area (``CEFHostView``). Such an event reaches the cmux window only
    /// where the page window takes no mouse: a blank page's cut-out, or the whole page when its window is detached,
    /// which shows its pixels from the hosted context but takes no click, scroll or key. No resize motion or
    /// first-frame hold of this view is under way while the pointer is on the page (a divider drag or a window live
    /// resize holds the pointer on the divider or the window edge), so a page still detached now is a leftover whose
    /// end never came (an end lost on its way, a refused attach nothing retried, a frame tick that never came). Its
    /// window comes back at once; before, only a window change brought it back (Aziz 2026-11-10: several browser tabs
    /// took no click or scroll until he closed and reopened the window).
    /// - Returns: Whether a detached page was attached now.
    @discardableResult
    func personReachedPage() -> Bool {
        // A page whose attach the fork refused is retried by the owed path (``attachIfOwed()``), not once per event.
        guard (isDetached && !attachOwed) || firstFrameHold != .none else { return false }
        return reattachLeftover(.pointer)
    }

    /// Ends every motion share, live resize and first-frame hold this view still counts, and attaches the page
    /// window: the state a page at rest has. A kept focus ask is granted once the window is in (``attach()``). One
    /// notice line with the state found, never a URL, so the path that left it can be found in the field.
    private func reattachLeftover(_ reach: LeftoverReach) -> Bool {
        let state = "detached=\(isDetached) owed=\(attachOwed) motions=\(motionHolders) drags=\(paneDragHolders) "
            + "liveResize=\(inLiveResize) hold=\(firstFrameHold)"
        Self.logger.notice("leftover detached page (\(reach.rawValue, privacy: .public)) browser=\(self.browser ?? -1, privacy: .public) \(state, privacy: .public)")
        CEFHostView.trackerStats.leftoverAttaches += 1
        motionHolders = 0
        motionKeepsAttached = false
        inLiveResize = view?.window?.inLiveResize ?? false
        shownFrame?.deactivate()
        shownFrame = nil
        if let grant = afterFirstFrame, owedGrant == nil { owedGrant = grant }
        afterFirstFrame = nil
        firstFrameHold = .none
        let wasDetached = isDetached
        attach()
        guard wasDetached, !isDetached else { return false }
        // The fork orders the window in at its next observer: a focus grant in this turn would move no keys, so
        // ``pageTakesFocus()`` keeps the ask until after the next commit (as for a motion's attach).
        reattachedAwaitingCommit = true
        afterCommit { [weak self] in self?.reattachedAwaitingCommit = false }
        return true
    }

    /// A leftover detached page was attached in this turn; cleared after the next commit.
    private(set) var reattachedAwaitingCommit = false

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef-hosting")

    private func motionChanged() {
        if inResizeMotion {
            motionKeepsAttached = holdsFocus()
            if !motionKeepsAttached { setDetached(true) }
        } else {
            motionKeepsAttached = false
            attach()
        }
    }

    // MARK: The frame a page shows in (SWITCH STALL 5)

    /// A hosted page shows in this turn (`CEFPaneHost.present`: Cmd-N's page built before the key, a workspace or pane
    /// shown again) and its input window is not in the window (`windowInWindow` false). Ordering it in (addChildWindow,
    /// then the overlay panel's re-add above it) is window-server work: the fork defers it to a run-loop observer meant
    /// for after the commit, but on macOS 27 the commit runs later (the update cycle) and that observer fires first, 7.6
    /// ms before the first frame on every Cmd-N (Time Profiler, cmux22, macOS 27.0, 60 Hz). Chrome shows the frame
    /// first and wires input after it. So the page is detached for this turn (the fork shows it from its hosted context
    /// with no window order) and attached once the window's next display frame came, after that pass's commit: right
    /// after the key's commit was too soon (v1: the order-in and its commit then ran before that frame's display tick,
    /// which came 30 to 40 ms after the key in half the presses). `grant` runs once the fork ordered the window in.
    /// A page in a resize motion, already detached, or not hosted is left as it is.
    func pageAppeared(windowInWindow: Bool, then grant: @escaping @MainActor () -> Void) {
        guard !windowInWindow, firstFrameHold == .none, !isDetached, !inResizeMotion, setDetached(true) else { return }
        firstFrameHold = .detached
        afterFirstFrame = grant
        runAfterFrameShown { [weak self] in self?.attachAfterFirstFrame() }
    }

    /// Whether a page shown in a recent turn is still on its way back into the window (``firstFrameHold``): it has no
    /// window to make key yet, so a focus grant keeps its ask and the hold's end grants it (one grant, no grant per
    /// pass).
    func holdsFirstFrame() -> Bool {
        firstFrameHold != .none
    }

    private func runAfterFrameShown(_ block: @escaping @MainActor @Sendable () -> Void) {
        if let afterFrameShown { return afterFrameShown(block) }
        shownFrame?.deactivate()
        let shown: @MainActor () -> Void = { [weak self] in
            self?.shownFrame = nil
            self?.afterCommit(block)
        }
        // A dropped tick (its window closed in the hold) counts as the frame, so no page stays detached until an ask,
        // but grants nothing: SetFocus would order a closed window's page front. The tab keeps its ask for its next show.
        let client = FrameClient(owner: "cef.first-frame-attach", isAnimation: false,
                                 scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app },
                                 dropped: { [weak self] in
                                     self?.afterFirstFrame = nil
                                     shown()
                                 }) { _ in
            shown()
            return false
        }
        shownFrame = client
        client.activate()
    }

    private func attachAfterFirstFrame() {
        guard firstFrameHold == .detached else { return }
        // A motion that began meanwhile owns the detached page: its landing attaches it, a grant attaches it now.
        guard !inResizeMotion else { return endFirstFrameHold() }
        // Attached already when its view changed windows or a motion landed meanwhile; the order-in still comes next pass.
        if isDetached { attachOwed = !setDetached(false) && isDetached }
        firstFrameHold = .attaching
        // The fork's order-in observer was added in this pass: it runs in the next one, before this block.
        afterCommit { [weak self] in
            guard let self, self.firstFrameHold == .attaching else { return }
            self.endFirstFrameHold()
        }
    }

    private func endFirstFrameHold() {
        let grant = afterFirstFrame
        firstFrameHold = .none
        afterFirstFrame = nil
        // The fork refused the attach: the page has no window to make key. The ask stays kept (the tab's pending
        // focus) for the attach that brings the window back (``attach()``).
        if attachOwed, isDetached { return owedGrant = grant }
        grant?()
    }

    /// Retries an attach a landing could not make (``attachOwed``); a new motion owns the page window again instead.
    private func attachIfOwed() {
        guard !inResizeMotion else { return attachOwed = false }
        attach()
    }

    /// Attaches the detached page (``attachOwed`` when the fork refused). An ask a refused hold kept is granted after
    /// the commit that follows, once the fork ordered the window in.
    private func attach() {
        attachOwed = !setDetached(false) && isDetached
        guard !attachOwed, owedGrant != nil else { return }
        afterCommit { [weak self] in
            guard let self, let grant = self.owedGrant else { return }
            self.owedGrant = nil
            grant()
        }
    }

    /// Detaches the hosted page's window or attaches it again; the fork's attach places it at the view's rect then,
    /// the one geometry update of the landing. False when no page is hosted, below fork API 30, or the fork refused;
    /// the state is unchanged then.
    @discardableResult
    private func setDetached(_ on: Bool) -> Bool {
        guard on != isDetached else { return true }
        guard page != nil, let browser, let call = fork?.setDetachedHosting else { return false }
        forkCalls += 1
        guard call(browser, on) else { return false }
        isDetached = on
        if on { CEFHostView.trackerStats.detaches += 1 } else { CEFHostView.trackerStats.attaches += 1 }
        return true
    }

    /// The page window over `view` is the app's key window.
    static func pageWindowIsKey(over view: NSView?) -> Bool {
        guard let view, let owner = view.window, let key = NSApp.keyWindow, key.parent === owner else { return false }
        return CEFTab.frame(key.frame, isPlacedAt: owner.convertToScreen(view.convert(view.bounds, to: nil)))
    }

    /// The view goes away (DevTools closed) or its page window closed: turns
    /// hosting off for the browser and drops the hosted view.
    func stop() {
        pending = .none
        // The page window closed: a drag's wait does not pass to the next one (an end that comes later is ignored).
        paneDragHolders = 0
        motionHolders = 0
        motionKeepsAttached = false
        if page != nil, let fork, let browser {
            forkCalls += 1
            _ = fork.setLayerHosting(browser, false)
        }
        dropPage()
        syncDeadline()
        browser = nil
    }

    private func request(retry: Bool) {
        pending = .scheduled(retry: retry)
        schedule { [weak self] in
            guard let self, self.pending == .scheduled(retry: retry) else { return }
            self.pending = .none
            guard let fork = self.fork, let browser = self.browser, self.isEnabled(), self.page == nil else { return }
            self.apply(fork, browser: browser, retry: retry)
        }
    }

    private func apply(_ fork: Fork, browser: Int32, retry: Bool) {
        guard let view else { return }
        forkCalls += 1
        let id = fork.setLayerHosting(browser, true)
        if id != 0 {
            let page = self.page ?? addPage(to: view)
            if page.host(contextID: id) {
                // The page's frame at a new size commits with the pane's only while hosted.
                syncDeadline()
                return
            }
            // No CALayerHost to show the context: the page window would stay
            // see-through over a blank view, so give the page its pixels back.
            forkCalls += 1
            _ = fork.setLayerHosting(browser, false)
            dropPage()
            refused()
            return
        }
        refused()
        if !retry { pending = .armed }
    }

    /// Gives the fork this page window's resize deadline when it changed
    /// (``CEFResizeSyncDeadline``): during the window's live resize every page's,
    /// else during a resize-sync pane drag every page's, else a hosted page's pane
    /// deadline, else 0 (a page in its own window never holds the commit outside
    /// a live resize or a drag).
    private func syncDeadline() {
        guard let browser, let setResizeSync = fork?.setResizeSync else { return }
        let tunable = inLiveResize ? liveResizeDeadlineMs()
            : inPaneDrag ? dragResizeDeadlineMs()
            : (page != nil ? resizeDeadlineMs() : 0)
        // A page that waits for nothing (0) needs no cap and reads no display.
        let deadline = tunable <= 0 ? 0 : CEFResizeSyncDeadline(tunableMilliseconds: tunable, refreshIntervals: shortestIntervals()).milliseconds
        guard deadline != appliedDeadlineMs else { return }
        // Recorded only when the fork took it, so a refused value is tried again at the next sync.
        if setResizeSync(browser, deadline) { appliedDeadlineMs = deadline }
    }

    private func refused() {
        refusals += 1
        CEFHostView.trackerStats.hostingRefused += 1
    }

    private func addPage(to view: NSView) -> CEFHostedPageView {
        let page = makePage(view.bounds)
        page.hole = pageHole
        // Below the tracker's probe and every other subview.
        view.addSubview(page, positioned: .below, relativeTo: nil)
        self.page = page
        return page
    }

    private func dropPage() {
        // The fork ends detached hosting when hosting goes off or the page window goes.
        isDetached = false
        attachOwed = false
        firstFrameHold = .none
        afterFirstFrame = nil
        owedGrant = nil
        shownFrame?.deactivate()
        shownFrame = nil
        guard let page else { return }
        page.removeFromSuperview()
        self.page = nil
    }

    /// Runs `block` on the main run loop at the end of this turn, after the
    /// caller's stack (Chromium's creation stack) returned.
    nonisolated static func atEndOfTurn(_ block: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            // main-proof: a CFRunLoopGetMain() block runs on the main thread
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(main)
    }
}
