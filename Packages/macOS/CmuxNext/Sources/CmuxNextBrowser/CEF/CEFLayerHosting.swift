import AppKit

/// Layer hosting (fork API 26) of the page window over one ``CEFHostView``:
/// asks the fork for the page window's Core Animation context and shows it in
/// a ``CEFHostedPageView`` at the bottom of the host view, following
/// `BrowserResizeTunables.layerHosting`.
///
/// The context belongs to the page window, not to a tab: every tab of a pane
/// shares it, so a tab switch inside a hosted pane makes no fork call. A new
/// page window (``pageWindowCreated(browser:fork:anchor:)``) drops the old
/// context.
///
/// A request made inside Chromium's creation stack (`OnAfterCreated`, the
/// DevTools opened event) can find no page window yet: Chromium adds the
/// WebContents to its window later in that stack. So a new page window's
/// request runs at the end of the run-loop turn, after the stack returned.
/// When the fork still refuses, the next read of the host view by the fork's
/// tracker (``trackerDidRead()``, proof that the tracker is attached) retries
/// once. A refusal after that is the page window's answer: no show asks
/// again (a show is the 10 ms tab-switch path); a new page window or a move
/// of the host view to another place (``pageMoved(browser:)``) does.
///
/// Every request addresses the page window's live browser (`anchor`), never
/// a browser saved earlier: the browser that created a window (a spare
/// window's or popup host's about:blank placeholder) can be closed by the
/// time a retry runs.
///
/// Tests drive it through ``Fork`` and the `schedule` seam, without Chromium.
final class CEFLayerHosting {
    /// The fork's layer hosting call: a seam, so tests run this state machine
    /// without Chromium.
    struct Fork {
        /// `cmux_shim_browser_set_layer_hosting`: the page window's context
        /// id (> 0) for `enabled`, 0 when off or refused.
        let setLayerHosting: (_ browser: Int32, _ enabled: Bool) -> UInt32

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32) {
            self.setLayerHosting = setLayerHosting
        }

        /// The shim's call; nil without a shim, below fork API 26, or when
        /// this process has no `CALayerHost` to show a context
        /// (`CEFHostedPageView.canShowContexts`, asked once per process).
        /// Nil makes every call here free: nothing reaches the fork.
        init?(shim: CEFShimLibrary?, apiVersion: Int32, canShowContexts: Bool = CEFHostedPageView.canShowContexts) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI, canShowContexts else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
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

    weak var view: NSView?
    /// The page's pixels in this window's layer tree; nil while the page
    /// draws in its own window.
    private(set) var page: CEFHostedPageView?
    /// Requests the fork refused, or hosted contexts no `CALayerHost` could
    /// show, for this host view (`debug.cef` `layer_hosting.refusals` sums
    /// the live host views).
    private(set) var refusals = 0
    /// Calls into the fork so far, for this host view.
    private(set) var forkCalls = 0
    /// The browser shown last (``pageShown(browser:)``): live when it was
    /// shown. The fallback address when no `anchor` was given.
    private var shownBrowser: Int32?
    /// The page window's live browser now (`CEFPaneHost.anchorBrowser`, the
    /// DevTools browser); nil when none is live.
    private var anchor: (() -> Int32?)?
    private var fork: Fork?
    private var pending = Pending.none
    /// The fork refused this page window after its retry (its tracker was
    /// attached): a show asks again only after ``pageMoved(browser:)``.
    private var windowRefused = false
    private let isEnabled: () -> Bool
    private let schedule: Scheduler
    private let makePage: (CGRect) -> CEFHostedPageView

    /// Runs a block later on the main actor.
    typealias Scheduler = (_ block: @escaping @MainActor @Sendable () -> Void) -> Void

    /// - Parameters:
    ///   - isEnabled: whether hosting is wanted; the tunable by default.
    ///   - schedule: runs a block at the end of this run-loop turn; tests run it when they choose.
    ///   - makePage: the hosted view for a frame; tests pass one whose layer host fails.
    init(isEnabled: @escaping () -> Bool = { BrowserResizeTunables.layerHosting.value },
         schedule: @escaping Scheduler = { CEFLayerHosting.atEndOfTurn($0) },
         makePage: @escaping (CGRect) -> CEFHostedPageView = { CEFHostedPageView(frame: $0) }) {
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.makePage = makePage
    }

    /// Whether a refused request waits for the tracker's next read.
    var isRetryArmed: Bool { pending == .armed }

    /// Whether the page draws in a cmux window's layer tree now (a hosted
    /// view in a window): what `debug.cef` `layer_hosting.hosted_pages` counts.
    var isHostedInWindow: Bool { page?.window != nil }

    /// A new page window over the view (a pane's Chromium window, or a docked
    /// DevTools): the old window's context went with it. Called inside
    /// Chromium's creation stack, so the request waits for the end of the turn.
    /// - Parameters:
    ///   - browser: the browser whose creation made the window.
    ///   - fork: the fork's call; nil when hosting cannot run in this process.
    ///   - anchor: the window's live browser at the time of a later request
    ///     (the creating browser may be closed by then); nil uses the browser
    ///     shown last.
    func pageWindowCreated(browser: Int32, fork: Fork?, anchor: (() -> Int32?)? = nil) {
        dropPage()
        shownBrowser = browser
        self.anchor = anchor
        self.fork = fork
        pending = .none
        windowRefused = false
        guard fork != nil, isEnabled() else { return }
        request(retry: false)
    }

    /// A tab of the page window shows (`CEFPaneHost.present`). While the page
    /// is hosted and hosting is still wanted, or the fork refused this page
    /// window, nothing reaches the fork; a tunable change applies here.
    func pageShown(browser: Int32) { // perf-hot: 10ms tab-switch (every Chromium tab show)
        guard let fork else { return }
        shownBrowser = browser
        let wanted = isEnabled()
        if wanted == (page != nil) { return }
        if wanted {
            if windowRefused { return }
            if case .scheduled = pending { return }
            pending = .none
            apply(fork, browser: browser, retry: false)
        } else {
            pending = .none
            _ = call(fork, browser, false)
            dropPage()
        }
    }

    /// The host view moved to another place (a docked DevTools changed side,
    /// or moved between the pane and its own window): the fork's tracker
    /// attaches anew, so a page window it refused may host now, and a tunable
    /// change applies. A person's placement choice, not a hot path: at most
    /// one fork call.
    func pageMoved(browser: Int32) {
        windowRefused = false
        pageShown(browser: browser)
    }

    /// The fork's tracker read the host view (`-cmuxClipPath`): it is attached
    /// to the page window now, so a refused request may succeed.
    func trackerDidRead() { // perf-hot: 1us cef-geometry (each tracker read)
        guard pending == .armed else { return }
        request(retry: true)
    }

    /// The page window closed (DevTools closed, the pane's last tab closed):
    /// drops the hosted view. No fork call: the window's browsers are gone
    /// by now, and the context belongs to the page window's tracker, which
    /// the window's teardown releases.
    func stop() {
        pending = .none
        dropPage()
        fork = nil
        anchor = nil
        shownBrowser = nil
        windowRefused = false
    }

    /// The page window's live browser now.
    private var liveBrowser: Int32? {
        if let anchor { return anchor() }
        return shownBrowser
    }

    private func request(retry: Bool) {
        pending = .scheduled(retry: retry)
        schedule { [weak self] in
            guard let self, self.pending == .scheduled(retry: retry) else { return }
            self.pending = .none
            guard let fork = self.fork, !self.windowRefused, self.isEnabled(), self.page == nil,
                  let browser = self.liveBrowser else { return }
            self.apply(fork, browser: browser, retry: retry)
        }
    }

    private func apply(_ fork: Fork, browser: Int32, retry: Bool) {
        guard let view else { return }
        let id = call(fork, browser, true)
        if id != 0 {
            let page = self.page ?? addPage(to: view)
            if page.host(contextID: id) { return }
            // No CALayerHost to show the context: the page window would stay
            // see-through over a blank view, so give the page its pixels back,
            // and ask no more for this page window (it would fail the same way).
            _ = call(fork, browser, false)
            dropPage()
            refusals += 1
            self.fork = nil
            return
        }
        refusals += 1
        if retry { windowRefused = true } else { pending = .armed }
    }

    private func call(_ fork: Fork, _ browser: Int32, _ enabled: Bool) -> UInt32 {
        forkCalls += 1
        return fork.setLayerHosting(browser, enabled)
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
