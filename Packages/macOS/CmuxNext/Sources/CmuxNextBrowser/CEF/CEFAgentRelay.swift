public import Foundation

/// What a raw DevTools send did (`cmux_shim_devtools_send`).
public nonisolated enum CEFDevToolsRawSend: Hashable, Sendable {
    /// Handed to the browser. The CEF relay reports a message the browser then refuses as a CDP
    /// error reply on its stream (``CEFAgentRelay/send(_:)``).
    case sent
    /// The tab has no Chromium browser (never shown, or closed).
    case noBrowser
    /// Refused before it was sent: the message has no one integer top-level raw id (>= 2^30).
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
    /// The first paint bridge reads the tab's DevTools events (before fork API 29), page tabs' too.
    private var firstPaintListens = false
    /// The media and verification bridges run on the tab's DevTools session (before fork API 29).
    private var bridgesAttached = false
    /// The tab holds a cmux page (``CEFEngine/makePagesTab(_:)``): the browser-tab bridges (media,
    /// verification) never attach, and their channels' posts are dropped. Its first paint still counts.
    /// Set before the browser exists.
    var servesCmuxPage = false

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

    /// Hears only the browser's end: no DevTools event delivery (a cmux page on renderer paths).
    public func set(onEnd: (() -> Void)?) {
        sink = nil
        self.onEnd = onEnd
        updateWatch()
    }

    /// Every renderer has the cmux page host (``CEFPageSchemes/HostScript``): Chromium started on
    /// renderer paths with the App's page host scripts, and the shim took them all with the page
    /// host relay and its channel. A cmux page then talks to its host over the page channel and
    /// opens no DevTools session; otherwise it sets its host up over DevTools.
    public var pageHostInRenderer: Bool { tab?.runtime.pageHostInRenderer == true }

    /// Someone reads the tab's DevTools events.
    private var listens: Bool { sink != nil || mediaListens || designModeListens || firstPaintListens }

    private func updateWatch() {
        if let tab, let browser = tab.browserID { tab.runtime.shim?.devToolsWatchEvents(browser, listens ? 1 : 0) }
    }

    /// Sends one raw DevTools message in this turn, in order with the tab's other ops; its "id"
    /// must be a raw id (>= 2^30). The shim's answer (1 sent, 0 the browser is gone, -1 refused)
    /// is the call's own in process and the host's REPLY in host mode
    /// (``CEFRuntime/whenSettled(_:label:timeout:then:)``). A message that cannot get Chromium's
    /// own reply (0, -1, or a host that exited or was never attached) comes back on the relay's
    /// stream as a CDP error reply with the message's id, as Chromium answers a message it cannot
    /// dispatch (`DevToolsSession::DispatchProtocolMessage`,
    /// content/browser/devtools/devtools_session.cc): `DevToolsAgentHost::DispatchProtocolMessage`
    /// returns nothing, and the client learns of a failure from the protocol. A host that has not
    /// answered by the deadline gets no made-up error: it may have sent the message, whose real
    /// reply then still comes, and the relay's close answers whatever stays pending.
    /// A message without one integer top-level raw id is `.refused` here, before anything is sent.
    public func send(_ message: String) -> CEFDevToolsRawSend {
        guard let tab, !tab.isClosed, let browser = tab.browserID, tab.runtime.shim != nil else { return .noBrowser }
        guard let id = CEFDevToolsRawMessage.topLevelID(in: message), CEFDevToolsRawMessage.isRawID(id) else { return .refused }
        let sent = tab.runtime.sendAsync { shim in shim.devToolsSend(browser, message) }
        tab.runtime.whenSettled(sent, label: "devtools send") { [weak self] settled in
            guard let text = Self.unansweredText(settled),
                  let reply = CEFDevToolsRawMessage.errorReply(id: id, sessionID: CEFDevToolsRawMessage.sessionID(in: message), text: text)
            else { return }
            self?.sink?(reply)
        }
        return .sent
    }

    /// The error text for a send whose real reply cannot come; nil when Chromium took it, or when a
    /// late answer is still possible (a passed deadline, a REPLY that did not decode).
    static func unansweredText(_ settled: Result<Int32, CEFHostReplyError>) -> String? {
        switch settled {
        case .success(1): nil
        case .success(0): "the tab's page has no browser"
        case .success: "Chromium refused the message"
        case .failure(.hostGone): "the Chromium Host exited"
        case .failure(.unsent): "the Chromium Host is not attached"
        case .failure: nil
        }
    }

    /// True once the Chromium browser exists.
    public var hasBrowser: Bool { tab?.browserID != nil }

    /// The page as the attached Chromium Host relays it straight to the browser host:
    /// nil in process, before the browser exists, without a relay link, or with a host that cannot relay (its
    /// HELLO did not list the provider link). The app relays such a page itself (``send(_:)``).
    public var directTarget: CEFAgentDirectTarget? {
        guard let tab, !tab.isClosed, let browser = tab.browserID, let hostStart = tab.runtime.hostStart,
              hostStart.relaysAgents, !hostStart.hostGone, let link = hostStart.agentRelayLink else { return nil }
        return CEFAgentDirectTarget(browser: browser, linkID: link.linkID)
    }

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
        // A cmux page runs no browser-tab script (`CEFDocumentScripts.cmuxPageGuard`), and a web
        // page no page host relay (`CEFDocumentScripts.cmuxPageOnlyGuard`): a post on a channel
        // the tab's kind does not run is not cmux's.
        guard servesCmuxPage ? message.channel.servesCmuxPages : message.channel.servesBrowserTabs else { return }
        switch message.channel {
        case .media: media?.report(message.payload)
        case .protectedMedia: media?.refused(message.payload)
        case .verification: verification?.report(message.payload)
        case .firstPaint: firstPaint?.painted()
        case .pageHost:
            guard let post = CEFDocumentScripts.pageHostPost(message.payload) else { return }
            onPageHostPost?(post.text, post.sender)
        }
    }

    /// Takes a cmux page's page host posts (``CEFPageMessage/Channel/pageHost``, its main frame
    /// only), in the order the tab's events deliver them: the page's text and the URL of the
    /// document that sent it (the relay's stamp, ``CEFDocumentScripts/pageHostPost(_:)``); nil drops them.
    public var onPageHostPost: ((_ text: String, _ sender: URL) -> Void)?

    /// The DOM event a cmux page fires to post to its page host on the page channel
    /// (``CEFDocumentScripts/pageHostEvent``); nil when the runtime installs no page channels
    /// (before fork API 29), so the page calls its DevTools binding.
    public var pageHostEvent: String? {
        guard let tab, tab.runtime.forkFeatures.rendererPaths else { return nil }
        return CEFDocumentScripts.pageHostEvent
    }

    func browserAttached() {
        resumeWaiters(true)
        // From fork API 29 the runtime installs the document scripts for every browser in the
        // renderer (`CEFDocumentScripts`): the tab opens no DevTools session for them. A page tab
        // gets only the first paint bridge.
        if let tab, let browser = tab.browserID, !tab.runtime.forkFeatures.rendererPaths {
            if !servesCmuxPage {
                bridgesAttached = true
                media?.attach(browser)
                verification?.attach(browser)
            }
            firstPaint?.attach(browser)
            firstPaintListens = true
        }
        if listens { updateWatch() }
    }

    /// The tab handled a shim event (`CEFTab.handle`): a document that committed or finished gets
    /// its bindings again. Chrome's `WebContentsObserver` hears navigations as callbacks the same way
    /// (content/public/browser/web_contents_observer.h), with no observation of the tab's state.
    func documentStateChanged() {
        guard bridgesAttached else { return }
        media?.documentChanged()
        verification?.documentChanged()
    }

    func resumeWaiters(_ created: Bool) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resolve(created) }
    }

    /// The browser closed: waiters fail and the relay hears the end once.
    func browserEnded() {
        resumeWaiters(false)
        bridgesAttached = false
        let end = onEnd
        sink = nil
        onEnd = nil
        end?()
    }
}
