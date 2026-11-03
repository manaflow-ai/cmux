import AppKit

/// Layer hosting (fork API 26) of the page window over one ``CEFHostView``:
/// asks the fork for the page window's Core Animation context and shows it in
/// a ``CEFHostedPageView`` at the bottom of the host view, following
/// `BrowserResizeTunables.layerHosting`.
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
/// While hosted (fork API 27), a resize of the page window may hold the
/// process's commit for Chromium's frame at the new size, up to
/// ``CEFResizeSyncDeadline``: the `browserResize.syncDeadline` tunable capped at
/// half the shortest frame of all displays. During the window's live resize
/// every page over the view, hosted or not, gets `browserResize.liveResizeDeadline`
/// under the same cap, and a person's drag of the view's pane with `browserResize.dragResize` at `resizeSync`
/// gives it `browserResize.dragResizeDeadline` (``paneResizeDrag(active:)``). A change (a tunable edit, a display added or changed)
/// reaches the fork at the next show or display change, only when the deadline
/// changed, and counts as applied only when the fork took it.
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

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32,
             setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)? = nil) {
            self.setLayerHosting = setLayerHosting
            self.setResizeSync = setResizeSync
        }

        /// The shim's call; nil without a shim or below fork API 26, where
        /// nothing changes and showing a tab costs nothing here.
        init?(shim: CEFShimLibrary?, apiVersion: Int32) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
            setResizeSync = apiVersion >= CEFLayerHosting.resizeSyncForkAPI
                ? { browser, timeout in shim.browserSetResizeSync(browser, timeout) == 1 } : nil
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

    weak var view: NSView?
    /// The page's pixels in this window's layer tree; nil while the page
    /// draws in its own window.
    private(set) var page: CEFHostedPageView?
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

    /// - Parameters:
    ///   - isEnabled: whether hosting is wanted; the tunable by default.
    ///   - schedule: runs a block at the end of this run-loop turn; tests run it when they choose.
    ///   - makePage: the hosted view for a frame; tests pass one whose layer host fails.
    ///   - resizeDeadlineMs: the upper bound of a hosted page's resize wait; the tunable by default.
    ///   - refreshIntervals: the shortest frame interval of each display, which cap the wait
    ///     (``CEFResizeSyncDeadline``); tests pass fixed rates.
    init(isEnabled: @escaping () -> Bool = { BrowserResizeTunables.layerHosting.value },
         schedule: @escaping Scheduler = { CEFLayerHosting.atEndOfTurn($0) },
         makePage: @escaping (CGRect) -> CEFHostedPageView = { CEFHostedPageView(frame: $0) },
         resizeDeadlineMs: @escaping () -> Int32 = { Int32((BrowserResizeTunables.syncDeadline.value * 1_000).rounded()) },
         liveResizeDeadlineMs: @escaping () -> Int32 = { Int32((BrowserResizeTunables.liveResizeDeadline.value * 1_000).rounded()) },
         dragResizeDeadlineMs: @escaping () -> Int32 = { Int32((BrowserResizeTunables.dragResizeDeadline.value * 1_000).rounded()) },
         refreshIntervals: @escaping () -> [Double] = { NSScreen.screens.map(\.minimumRefreshInterval) }) {
        self.isEnabled = isEnabled
        self.resizeDeadlineMs = resizeDeadlineMs
        self.liveResizeDeadlineMs = liveResizeDeadlineMs
        self.dragResizeDeadlineMs = dragResizeDeadlineMs
        self.refreshIntervals = refreshIntervals
        self.schedule = schedule
        self.makePage = makePage
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
        syncDeadline()
    }

    /// The host view moved to another window (`CEFHostView.viewDidMoveToWindow`):
    /// a tunable edit made while it was out of every window applies now. Leaving
    /// a window makes no fork call: the cap is every display's, not the window's.
    /// The new window's live resize state replaces the old one: AppKit tells only
    /// the views in a window when its live resize starts and ends.
    func windowDidChange() {
        inLiveResize = view?.window?.inLiveResize ?? false
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
    }

    /// The window starts or ends a live resize (`CEFHostView.viewWillStartLiveResize`). Fork API 27 never lets a page
    /// window hold the window's commit unless asked, so for the live resize every page over the view, hosted or not,
    /// waits up to `liveResizeDeadlineMs` (capped like every deadline, ``CEFResizeSyncDeadline``) for its frame at the
    /// new size (Chromium waited up to 500 ms there); after it a hosted page goes back to its pane deadline and a page
    /// window to none.
    func windowLiveResize(active: Bool) {
        guard active != inLiveResize else { return }
        inLiveResize = active
        syncDeadline()
    }

    /// A person's divider or edge drag of the view's pane began (`true`) or its release landed (`false`), with
    /// `browserResize.dragResize` at `resizeSync` (`CEFTabContentView.paneResizeGestureDidChange`). Every frame of the
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
        guard pending == .armed else { return }
        request(retry: true)
    }

    /// The view goes away (DevTools closed) or its page window closed: turns
    /// hosting off for the browser and drops the hosted view.
    func stop() {
        pending = .none
        // The page window closed: a drag's wait does not pass to the next one (an end that comes later is ignored).
        paneDragHolders = 0
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
        let deadline = CEFResizeSyncDeadline(tunableMilliseconds: tunable, refreshIntervals: refreshIntervals()).milliseconds
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
        // Below the tracker's probe and every other subview.
        view.addSubview(page, positioned: .below, relativeTo: nil)
        self.page = page
        return page
    }

    private func dropPage() {
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
