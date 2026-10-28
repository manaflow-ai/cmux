import Foundation

/// What a raw DevTools send did (`cmux_shim_devtools_send`).
public nonisolated enum CEFDevToolsRawSend: Hashable, Sendable {
    case sent
    /// The tab has no Chromium browser (never shown, or closed).
    case noBrowser
    /// The shim refused the message (not a JSON object, an "id" below 2^30,
    /// or Chromium refused it).
    case refused
}

/// The browser host's raw DevTools relay of one CEF tab
/// (plans/cmux-next/browser-host.md, "CEF relay"). The relay owns every raw
/// id (>= 2^30, `CEFDevToolsRawMessage`): no other app code calls
/// `cmux_shim_devtools_send`. The shim header does not change, so the shim
/// ABI identity stays the same.
public final class CEFAgentRelay {
    private weak var tab: CEFTab?
    private var sink: ((String) -> Void)?
    private var onEnd: (() -> Void)?
    private var waiters: [OneShot<Bool>] = []
    /// The media hub's binding reports arrive as protocol events too: the
    /// bridge takes its own, and the browser's events stay on while it
    /// listens, relay or not.
    private lazy var media = tab.map { CEFMediaBridge(tab: $0) }
    /// The email verification detector's binding reports (`CEFVerificationBridge`), on the same events.
    private lazy var verification = tab.map { CEFVerificationBridge(tab: $0) }
    var mediaListens = false { didSet { updateWatch() } }
    /// When a document first paints content (`CEFFirstPaintBridge`), on the
    /// same events; it only reads them, so it never takes one off the stream.
    private lazy var firstPaint = tab.map { CEFFirstPaintBridge(tab: $0) }
    /// Design mode's binding posts (`CEFDesignModeBridge`), on the same events once the user turned it on.
    private lazy var designMode = tab.map { CEFDesignModeBridge(tab: $0) }
    var designModeListens = false { didSet { updateWatch() } }

    init(tab: CEFTab) { self.tab = tab }

    /// Starts relaying (`onMessage` set): every raw DevTools message of the
    /// tab's browser (replies to `send` and the protocol events of the
    /// domains the relay turned on) goes to `onMessage`, and `onEnd` runs
    /// once when the browser goes away. Nil stops the relay. A relay started
    /// before the browser exists takes effect when it is created.
    public func set(onMessage: ((String) -> Void)?, onEnd: (() -> Void)?) {
        sink = onMessage
        self.onEnd = onMessage == nil ? nil : onEnd
        updateWatch()
    }

    private func updateWatch() {
        if let tab, let browser = tab.browserID { tab.runtime.shim?.devToolsWatchEvents(browser, sink != nil || mediaListens || designModeListens ? 1 : 0) }
    }

    /// Sends one raw DevTools message; its "id" must be a raw id (>= 2^30).
    public func send(_ message: String) -> CEFDevToolsRawSend {
        guard let tab, !tab.isClosed, let browser = tab.browserID, let shim = tab.runtime.shim else { return .noBrowser }
        switch message.withCString({ shim.devToolsSend(browser, $0) }) {
        case 1: return .sent
        case 0: return .noBrowser
        default: return .refused
        }
    }

    /// True once the Chromium browser exists.
    public var hasBrowser: Bool { tab?.browserID != nil }

    /// No pane shows the tab, nor any other tab of its pane's Chromium window:
    /// that window is in no app window, so Chromium draws no frame for it
    /// (screenshots never answer). The App then moves the tab's content
    /// view into its off-screen render window, which presents the tab there.
    /// False while a pane shows another tab of the same window: the tab is a
    /// background tab of a drawn window then, and moving it would take the
    /// window from that pane.
    public var needsRenderWindow: Bool {
        // A tab its pane parked hidden (PaneContentView+Parking) is in the
        // window but not drawn: a background tab too.
        guard let tab, !tab.isClosed, tab.contentView.window == nil || tab.contentView.isHiddenOrHasHiddenAncestor else { return false }
        return tab.host.visibleTab == nil
    }

    /// Creates the Chromium browser of a tab that was never shown, in the
    /// background (the pane host's own creation path; nothing is shown and
    /// focus does not move). Agents drive hidden tabs.
    public func createBrowser() {
        guard let tab, !tab.isClosed else { return }
        tab.host.ensureCreated(tab)
    }

    /// Resumes with true once the browser exists, false when its creation
    /// failed, the tab closed, or the waiting task was cancelled.
    public func browserCreated() async -> Bool {
        guard let tab else { return false }
        if tab.browserID != nil { return true }
        if tab.isClosed { return false }
        let waiter = OneShot<Bool>()
        waiters.removeAll { $0.isResolved }
        waiters.append(waiter)
        // concurrency-allow: OneShot.wait is an async suspension, not a blocking wait
        return await waiter.wait(cancelled: false)
    }

    // MARK: Tab lifetime (CEFTab)

    func deliver(_ json: String) {
        // Reads the stream and always returns false, so a relayed agent that
        // subscribed to page lifecycle events still sees them.
        _ = firstPaint?.handle(json)
        if media?.handle(json) == true { return }
        if verification?.handle(json) == true { return }
        if designMode?.handle(json) == true { return }
        sink?(json)
    }

    /// Readies the page to post design mode messages (``CEFDesignModeBridge/prepare()``).
    func prepareDesignMode() async throws {
        guard let designMode else { throw BrowserTabError.closed }
        try await designMode.prepare()
    }

    /// A page posted on one of cmux's channels (fork API 29): the same reports the DevTools
    /// bindings carry before it, to the same bridges.
    func pageMessage(_ message: CEFPageMessage) {
        switch message.channel {
        case .media: media?.report(message.payload)
        case .protectedMedia: media?.refused(message.payload)
        case .verification: verification?.report(message.payload)
        case .firstPaint: firstPaint?.painted()
        }
    }

    func browserAttached() {
        resumeWaiters(true)
        // From fork API 29 the runtime installs the document scripts for every browser in the
        // renderer (`CEFDocumentScripts`): the tab opens no DevTools session for them.
        if let tab, let browser = tab.browserID, !tab.runtime.forkFeatures.rendererPaths {
            media?.attach(browser)
            verification?.attach(browser)
            firstPaint?.attach(browser)
        }
        if sink != nil || mediaListens || designModeListens { updateWatch() }
    }

    func resumeWaiters(_ created: Bool) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resolve(created) }
    }

    /// The browser closed: waiters fail and the relay hears the end once.
    func browserEnded() {
        resumeWaiters(false)
        let end = onEnd
        sink = nil
        onEnd = nil
        end?()
    }
}
