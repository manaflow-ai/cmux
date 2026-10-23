import AppKit
import CmuxNextCompat

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
/// While hosted (fork API 27), a resize of the page window may hold this
/// window's commit for Chromium's frame at the new size, up to
/// ``CEFResizeSyncDeadline``: the `browserResize.syncDeadline` tunable capped at
/// half a frame of the window's display. A change of either (a tunable edit, the
/// window on another display) reaches the fork at the next show or screen
/// change, and only when the deadline changed.
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
        /// resize of the page window may hold this window's commit for
        /// Chromium's frame at the new size, in ms; 0 never holds it. Nil
        /// below API 27, where Chromium holds it up to 500 ms on every resize.
        let setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Void)?

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32,
             setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Void)? = nil) {
            self.setLayerHosting = setLayerHosting
            self.setResizeSync = setResizeSync
        }

        /// The shim's call; nil without a shim or below fork API 26, where
        /// nothing changes and showing a tab costs nothing here.
        init?(shim: CEFShimLibrary?, apiVersion: Int32) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
            setResizeSync = apiVersion >= CEFLayerHosting.resizeSyncForkAPI
                ? { browser, timeout in _ = shim.browserSetResizeSync(browser, timeout) } : nil
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
    private var browser: Int32?
    private var fork: Fork?
    private var pending = Pending.none
    private let isEnabled: () -> Bool
    private let schedule: Scheduler
    private let makePage: (CGRect) -> CEFHostedPageView
    private let resizeDeadlineMs: () -> Int32
    private let liveResizeDeadlineMs: () -> Int32
    private let refreshInterval: (NSWindow?) -> Double?
    /// The resize deadline the fork has for this page window: 0, the fork's default, until
    /// ``syncDeadline()`` gives another.
    private var appliedDeadlineMs: Int32 = 0
    /// Re-applies the deadline when the view's window moves to another display.
    private var screenObservation: MainActorObservation?
    /// The window is in a live resize (``windowLiveResize(active:)``).
    private var inLiveResize = false

    /// Runs a block later on the main actor.
    typealias Scheduler = (_ block: @escaping @MainActor @Sendable () -> Void) -> Void

    /// - Parameters:
    ///   - isEnabled: whether hosting is wanted; the tunable by default.
    ///   - schedule: runs a block at the end of this run-loop turn; tests run it when they choose.
    ///   - makePage: the hosted view for a frame; tests pass one whose layer host fails.
    ///   - resizeDeadlineMs: the upper bound of a hosted page's resize wait; the tunable by default.
    ///   - refreshInterval: the shortest frame interval of a window's display, which caps the wait
    ///     (``CEFResizeSyncDeadline``); tests pass a fixed rate.
    init(isEnabled: @escaping () -> Bool = { BrowserResizeTunables.layerHosting.value },
         schedule: @escaping Scheduler = { CEFLayerHosting.atEndOfTurn($0) },
         makePage: @escaping (CGRect) -> CEFHostedPageView = { CEFHostedPageView(frame: $0) },
         resizeDeadlineMs: @escaping () -> Int32 = { Int32((BrowserResizeTunables.syncDeadline.value * 1_000).rounded()) },
         liveResizeDeadlineMs: @escaping () -> Int32 = { Int32((BrowserResizeTunables.liveResizeDeadline.value * 1_000).rounded()) },
         refreshInterval: @escaping (NSWindow?) -> Double? = { $0?.screen?.minimumRefreshInterval }) {
        self.isEnabled = isEnabled
        self.resizeDeadlineMs = resizeDeadlineMs
        self.liveResizeDeadlineMs = liveResizeDeadlineMs
        self.refreshInterval = refreshInterval
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

    /// The host view moved to another window (or out of one,
    /// `CEFHostView.viewDidMoveToWindow`): the display that caps the resize
    /// wait may differ, and the window's later screen changes re-apply it.
    func windowDidChange() {
        screenObservation = nil
        if let window = view?.window {
            screenObservation = MainActorObservation(NSWindow.didChangeScreenNotification, object: window) { [weak self] in
                self?.syncDeadline()
            }
        }
        syncDeadline()
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
    /// else a hosted page's pane deadline, else 0 (a page in its own window never
    /// holds the commit outside a live resize).
    private func syncDeadline() {
        guard let browser, let setResizeSync = fork?.setResizeSync else { return }
        let tunable = inLiveResize ? liveResizeDeadlineMs() : (page != nil ? resizeDeadlineMs() : 0)
        let deadline = CEFResizeSyncDeadline(tunableMilliseconds: tunable,
                                             refreshInterval: refreshInterval(view?.window)).milliseconds
        guard deadline != appliedDeadlineMs else { return }
        appliedDeadlineMs = deadline
        setResizeSync(browser, deadline)
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
