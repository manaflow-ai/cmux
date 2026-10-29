public import AppKit
import CmuxNextDesign
import CmuxNextErrorJournal
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

// Chromium mode (`browser.defaultEngine` is `chromium`, ``PageEnginePolicy``): the page shows in a
// Chromium page from ``PageWebView/chromiumHosting``, over the same router, theme and scripts. It
// has no WebKit view: a page that fails in Chromium builds its WebKit engine and reopens there in
// the same turn (``fallBackToWebKit(_:detail:)``); one whose browser ended waits (PageChromiumRecovery.swift).
extension PageWebView {
    /// The handlers the page scripts post to without a reply, in Chromium mode.
    static let chromiumFireAndForget = [
        PagePaintProbe.handlerName, PageInputReadiness.handlerName, ConsoleErrorCapture.handlerName,
        PageChromiumDocumentScripts.navigateHandler, PageChromiumDocumentScripts.hostDropHandler,
    ]

    /// How long after a drag of files entered the page its drop may still open one in the host.
    static let chromiumDropWindow: TimeInterval = 120

    /// The engine `descriptor` made with `options` shows in now: the one decision every page view
    /// takes (``PageEnginePolicy``, with the app's ``chromiumHosting``).
    ///
    /// - Parameters:
    ///   - descriptor: The page.
    ///   - options: Its engine options.
    ///   - hosting: The Chromium host (the app's ``chromiumHosting`` by default).
    /// - Returns: Chromium, or WebKit and why.
    public static func engineDecision(for descriptor: PageDescriptor, options: PageEngineOptions,
                                      hosting: (any PageChromiumHosting)? = PageWebView.chromiumHosting) -> PageEngineDecision {
        // A live web override reaches only WebKit pages. Its watch is armed by the first page the host
        // opens in either engine, a preloaded one included (``WebUIHost/devOverride``), so a launch whose
        // first page is a Chromium one still reads web-dev.json.
        return engineDecisionNow(for: descriptor, options: options, hosting: hosting)
    }

    /// ``engineDecision(for:options:hosting:)`` with the Chromium host given: for a caller that only asks
    /// where a page would show.
    ///
    /// - Parameters:
    ///   - descriptor: The page.
    ///   - options: Its engine options.
    ///   - hosting: The Chromium host; nil for WebKit only.
    /// - Returns: Chromium, or WebKit and why.
    static func engineDecisionNow(for descriptor: PageDescriptor, options: PageEngineOptions,
                                  hosting: (any PageChromiumHosting)?) -> PageEngineDecision {
        guard let hosting else {
            // No Chromium host (a build or test without one): a page that could not run there keeps
            // its own reason, any other one is on WebKit because Chromium is missing.
            return PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: descriptor, options: options)
        }
        return PageEnginePolicy(preference: hosting.preference, chromiumAvailable: hosting.isAvailable,
                                chromiumServes: hosting.serves(descriptor),
                                liveWebOverride: WebDevOverride.current.isActive).decide(for: descriptor, options: options)
    }

    /// The view that takes the keyboard when the page is focused: Chromium's view or the WebKit view;
    /// this view while its Chromium page is on its way (the page's attach hands the keyboard on).
    public var focusView: NSView { chromiumSession?.page.contentView ?? webKitPieces?.view ?? self }

    /// The Chromium page that shows the page now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { chromiumSession?.page }

    /// The page zoom both engines show: `uiScale` times ``additionalZoom``, the view points per CSS
    /// pixel (WebKit pages take no pinch or smart magnification, ``PageWKWebView``).
    public var pageZoom: Double { Double(DesignSettings.shared.uiScale) * additionalZoom }

    /// Tells a Chromium page whether it shows (a hidden one stops drawing), the router's hidden hold
    /// (``holdDeliveryWhileHidden(visible:)``), and the census. A frozen
    /// page thaws before it shows, whichever path showed it (``thawPage()``, which runs its held
    /// pushes); the glass feed stops while the page is hidden and pushes what changed on the show's
    /// next frame (``GlassBackdropFeed/setPageShown(_:)``); a page whose renderer died while hidden reloads as it shows (``PageCrashRecovery/engineVisibilityChanged(_:page:)``); a page
    /// that hangs shows its "Page unresponsive" card only while it shows (``PageHangNotice``); a page
    /// whose web files changed while it was hidden (``bundleStale``, set only with feature
    /// `webUpdateReloadOnShow`) is handed to the safe point as it shows (``WebBundleSafePoint``), which
    /// asks it before it reloads, so a reload never loses what it holds; its crash reload loads the
    /// new files instead. A parked preload keeps its mark for its claim, which loads the new files
    /// (``bindClaim(routes:route:documentAttributes:surface:dynamicResources:)``).
    func setEngineVisible(_ visible: Bool) {
        engineVisible = visible
        if visible { thawPage() }
        glassFeed.setPageShown(visible)
        chromiumSession?.page.setVisible(visible)
        chromiumSession?.hang.visibilityChanged(visible)
        holdDeliveryWhileHidden(visible: visible)
        let showsStale = visible && bundleStale && !isParkedSpare
        if showsStale, crash.needsReload { bundleStale = false }
        crash.engineVisibilityChanged(visible, page: self)
        if showsStale, bundleStale { bundleSafePoint?.staleShown(self) }
        #if DEBUG || CMUX_BENCH_HOOKS
        noteCensusVisibility(visible)
        #endif
        if visible { chromiumRecovery?.pageShown() }
    }

    /// Loads `url` (a document of this page) in whichever engine shows it; a Chromium page on its way
    /// loads ``route`` when it attaches, and a page waiting to show after a crash loads it as it shows
    /// (``PageCrashRecovery/mayLoad(_:)``).
    func loadDocument(_ url: URL) {
        guard crash.mayLoad(url) else { return }
        traceOpenLoadStarted(.load)
        if let chromiumSession { chromiumSession.page.load(url) } else { webKitPieces?.view.load(URLRequest(url: url)) }
    }

    /// Reloads the document in whichever engine shows it; a Chromium page on its way loads fresh when it
    /// attaches, and a page waiting after a crash after its show.
    func reloadPage() {
        guard crash.mayLoad(nil) else { return }
        traceOpenLoadStarted(.reload)
        if let chromiumSession { chromiumSession.page.reload() } else { _ = webKitPieces?.view.reload() }
    }

    // MARK: Start

    /// Starts the Chromium page and loads the document at ``route`` in it (as it stands once the page
    /// exists, so an ``open(route:)`` meanwhile wins); falls back to WebKit when that fails or the
    /// page does not reach the host in time. A browser that ends with its Chromium Host while the page
    /// is made or set up waits for the supervisor instead (``PageChromiumRecovery``). `origin` goes to the host as
    /// the engine's tab origin, whose launch order is the only wait for a restored page.
    func startChromium(hosting: any PageChromiumHosting, origin: PageChromiumOrigin) {
        traceMark(.chromiumStart)
        webKitPieces?.view.isHidden = true
        let scripts = PageChromiumDocumentScripts(controller: userContent)
        let descriptor = descriptor
        let chatOpen = chatOpen
        #if DEBUG || CMUX_BENCH_HOOKS
        let traced = ChatOpenTrace.shared.isTraced(page: self)
        #endif
        // main-hop-allow: makePage and attachChromium are the Chromium host's main-actor async calls (the page is made over IPC) with cancel checks between; the task only runs them
        chromiumStart = Task { [weak self] in
            let page: any PageChromiumPage
            // Read in the task's turn, after the opening turn set it (``PageOpenRequest/chromiumWindow``).
            let window = self?.chromiumWindow
            do {
                #if DEBUG || CMUX_BENCH_HOOKS
                ChatOpenTrace.shared.makingTracedPage = traced
                #endif
                page = try await hosting.makePage(descriptor, chatOpen: chatOpen, window: window, origin: origin)
            } catch {
                // Cancelled: the page closed, was discarded, fell back or its browser ended meanwhile.
                guard let self, !Task.isCancelled else { return }
                return self.chromiumStartFailed(error, detail: "\(error)")
            }
            guard let self, !Task.isCancelled else { return page.close() }
            traceMark(.browserCreated)
            await self.attachChromium(page, scripts: scripts, work: hosting.work, dialogs: hosting.dialogs, madeIn: window)
        }
    }

    /// `madeIn`: the pane window the page was made in; a tab that moved to another pane meanwhile moves the page
    /// there once it is the view's page.
    private func attachChromium(_ page: any PageChromiumPage, scripts: PageChromiumDocumentScripts, work: BackgroundWork,
                                dialogs: CmuxDialogCenter, madeIn: PageChromiumWindow?) async {
        let handlers = Self.chromiumFireAndForget + chromiumMessageHandlers.keys.sorted()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: handlers)
        // Hidden until the attach below tells it whether the page shows; then ``setEngineVisible(_:)`` does.
        let hang = PageHangNotice(center: dialogs, anchor: self, visible: false) { [weak page] terminate in
            page?.answerUnresponsive(terminate: terminate)
        }
        let session = PageChromiumSession(page: page, bridge: bridge, work: work, deadlines: chromiumDeadlines, hang: hang)
        page.onEvent = { [weak self] event in self?.chromiumEvent(event) }
        page.resources = { [weak self] url in await self?.chromiumResource(url) ?? .notFound }
        do {
            for (method, params) in ChromiumPageHostBridge.setupCalls(handlers: handlers, documentScripts: scripts.sources,
                                                                       channelEvent: page.pageHostEvent) {
                _ = try await page.devTools(method, params: params)
            }
        } catch {
            session.end()
            guard !Task.isCancelled else { return }
            return chromiumStartFailed(error, detail: "setup: \(error)")
        }
        guard !Task.isCancelled else { return session.end() }
        traceMark(.setupDone)
        bridge.install { [weak self] message in await self?.receive(message) }
        bridge.onMessage = { [weak self] name, body in self?.chromiumMessage(name, body: body) }
        bridge.onFirstMessage = { [weak session] in session?.deadline.cancel() }
        inputReadiness.editor = { [weak self, weak page] edit, expectedEpoch in
            guard let page else { return false }
            return await Self.apply(edit, token: self?.inputReadiness.editToken, expectedEpoch: expectedEpoch, in: page)
        }
        chromiumSession = session
        if let chromiumWindow, chromiumWindow != madeIn { page.moveWindow(to: chromiumWindow) }
        scriptTarget.bridge = bridge
        bridge.evaluate(DesignSettings.shared.interfaceScaleScript) // MQ12 allowed: a starting page never froze
        page.setZoom(pageZoom)
        // The WebKit page draws no background (`drawsBackground` off): the Chromium page neither.
        page.setSeeThrough(true)
        page.contentView.frame = bounds
        page.contentView.autoresizingMask = [.width, .height]
        addSubview(page.contentView)
        applyNativeRects()
        // visibility-walk-allow: the engine's visibility is the AppKit state its view shows in, as setEngineVisible reads it; one walk per attach
        let shown = window != nil && !isHiddenOrHasHiddenAncestor
        page.setVisible(shown)
        session.hang.visibilityChanged(shown)
        traceMark(.navigationStart)
        page.load(descriptor.url(route: route))
        let wait = chromiumDeadline
        // The page's first message cancels the deadline (onFirstMessage); ending the session too.
        session.deadline.schedule(after: wait) { [weak self, weak session] in
            guard let self, let session, self.chromiumSession === session else { return }
            self.fallBackToWebKit(.chromiumFailed, detail: "no message from the page within \(wait)")
        }
        // The keyboard went to the page while Chromium started: this view held it.
        if shouldFocusOnAttach == false, let responder = window?.firstResponder,
           responder === self || responder === webKitPieces?.view { focusPage() }
    }

    /// The page was not made or set up: a browser that ended with its Chromium Host waits for the
    /// supervisor, shown or hidden; any other failure reopens the page in WebKit now.
    private func chromiumStartFailed(_ error: any Error, detail: String) {
        if error as? PageChromiumStartError == .browserEnded { return PageChromiumRecovery.browserEnded(self) }
        fallBackToWebKit(.chromiumFailed, detail: detail)
    }

    /// Chromium failed for this page: it builds its WebKit engine and reopens there, in this turn, at
    /// the route it showed; a wait for the supervisor ends.
    func fallBackToWebKit(_ reason: PageWebKitReason, detail: String) {
        chromiumStart?.cancel()
        chromiumStart = nil
        chromiumRecovery = nil
        logger.error("page \(self.descriptor.id, privacy: .public) reopens in WebKit: \(detail, privacy: .public)")
        chromiumSession?.end()
        chromiumSession = nil
        chromiumUserEventUptime = nil
        chromiumDragFile = nil
        inputReadiness.editor = nil
        engineDecision = .webKit(reason)
        let engine = webKit
        scriptTarget.bridge = engine.bridge
        engine.view.isHidden = false
        // The keyboard this view held while Chromium started goes to the WebKit view.
        if window?.firstResponder === self { window?.makeFirstResponder(engine.view) }
        router.reset()
        loaded = false
        traceOpenLoadStarted(.reload)
        engine.view.load(URLRequest(url: descriptor.url(route: route)))
        carryFreezeToWebKit()
    }

    /// Ends the Chromium page (the page closed, was discarded or its browser ended). A wait for the
    /// supervisor stays: a discarded page still reopens as its answer says when it shows.
    func endChromium() {
        chromiumStart?.cancel()
        chromiumStart = nil
        chromiumSession?.end()
        chromiumSession = nil
        inputReadiness.editor = nil
        if case .chromium? = frozenEngine { frozenEngine = nil }
    }

    // MARK: Events

    private func chromiumEvent(_ event: PageChromiumEvent) {
        // Before the session check: a browser can end while its page is set up, before the session.
        if event == .ended { return chromiumBrowserEnded() }
        guard let chromiumSession else { return }
        switch event {
        case .devTools(let json):
            guard !chromiumSession.bridge.receive(devToolsMessage: json),
                  let event = ChromiumPageHostWire.documentEvent(json) else { return }
            chromiumEvent(event)
        case .pageHostPost(let text, let sender):
            chromiumSession.bridge.receive(pageHostPost: text, sender: sender)
        case .committed(let url):
            // Before the policy: the posts that follow are this document's, whichever it is. The
            // ones it sent before this event are delivered once the view has reset for it.
            let held = chromiumSession.bridge.documentCommitted(url)
            guard let url, url.scheme != "about" else { return }
            guard PageNavigation.policy(for: url, page: descriptor, userClicked: false, mainFrame: true, hook: onNavigate) == .allow else {
                // A navigation the click script did not catch (a script set `location`): the page
                // comes back, and the URL opens where a link would.
                openOutside(url, modifiers: [])
                chromiumSession.page.load(descriptor.url(route: route))
                return
            }
            chromiumSession.bridge.rebind()
            documentCommitted()
            chromiumSession.bridge.replay(held)
        case .finished:
            documentFinished()
        case .loadFailed:
            documentFailed()
        case .crashed:
            chromiumSession.hang.end()
            contentProcessTerminated()
        case .unresponsive:
            chromiumSession.hang.unresponsiveChanged(true)
        case .responsive:
            chromiumSession.hang.unresponsiveChanged(false)
        case .ended:
            chromiumBrowserEnded()
        case .openRequested(let url):
            openOutside(url, modifiers: [])
        case .filesDragged(let urls):
            filesDragged(urls)
        case .userInput(let uptime):
            chromiumUserInput(at: uptime)
        case .contextMenu(let request):
            showChromiumMenu(request)
        }
    }

    /// The page's browser ended, shown, set up or still made (``PageChromiumEvent/ended``): it waits
    /// for the supervisor. A page that closed, fell back or was discarded has no start and no session,
    /// and a page that waits already ignores it.
    private func chromiumBrowserEnded() {
        // A closed page waiting for its engine close asks no supervisor for a new browser.
        guard !router.isEnded, chromiumSession != nil || chromiumStart != nil else { return }
        PageChromiumRecovery.browserEnded(self)
    }

    private func chromiumMessage(_ name: String, body: Any) {
        switch name {
        case PagePaintProbe.handlerName:
            notePainted()
        case PageInputReadiness.handlerName:
            inputReadiness.receive(body)
        case ConsoleErrorCapture.handlerName:
            ConsoleErrorCapture(page: descriptor.id).record(body)
        case PageChromiumDocumentScripts.hostDropHandler:
            hostDropped()
        case PageChromiumDocumentScripts.navigateHandler:
            guard let object = body as? [String: Any], let text = object["url"] as? String, let url = URL(string: text) else { return }
            var modifiers: NSEvent.ModifierFlags = []
            if object["command"] as? Bool == true { modifiers.insert(.command) }
            if object["shift"] as? Bool == true { modifiers.insert(.shift) }
            if object["option"] as? Bool == true { modifiers.insert(.option) }
            if object["control"] as? Bool == true { modifiers.insert(.control) }
            noteTouch()
            switch PageNavigation.policy(for: url, page: descriptor, userClicked: true, mainFrame: true, hook: onNavigate) {
            case .allow: chromiumSession?.page.load(url)
            case .openExternal: openOutside(url, modifiers: modifiers)
            case .cancel: break
            }
        default:
            chromiumMessageHandlers[name]?(body)
        }
    }

    /// A drag of files from outside entered the Chromium page: the first one goes to the host when
    /// ``fileDrop`` takes it (as on the WebKit page), and the page script hands the drop over.
    private func filesDragged(_ urls: [URL]) {
        let url = urls.first.flatMap { url in fileDrop.flatMap { $0.accepts(url) ? url : nil } }
        chromiumDragFile = url.map { ($0, now()) }
        chromiumSession?.bridge.evaluate("window.__cmuxHostDrop && window.__cmuxHostDrop(\(url != nil))") // MQ12 allowed: a drag enters a shown page
    }

    /// The page script handed a drop over. Only the file of a real drag the host took opens, once,
    /// and only soon after it entered: page script can post this message but cannot name a file.
    private func hostDropped() {
        guard let pending = chromiumDragFile else { return }
        chromiumDragFile = nil
        guard now().timeIntervalSince(pending.at) < Self.chromiumDropWindow, let fileDrop else { return }
        noteTouch()
        fileDrop.take(pending.url, keep: keepReasons)
    }

    /// Opens a link that leaves the page as WebKit's policy does (``onOpenExternal`` or the shared rule).
    private func openOutside(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        externalLinkModifiers = modifiers
        let other = LinkRouter.isOtherTarget(modifiers)
        (onOpenExternal ?? { LinkRouter.shared.open($0, otherTarget: other) })(url)
    }

    /// Chromium's request for `url`, one of the page's dynamic paths: what the WebKit scheme handler
    /// answers (``PageSchemeHandler/dynamicResponse(to:source:)``). A URL of another origin or
    /// outside the page's dynamic prefixes is a 404 that never reaches ``dynamicResources``.
    func chromiumResource(_ url: URL) async -> PageChromiumResponse {
        guard let request = PageSchemeHandler.dynamicRequest(for: url, page: descriptor) else { return .notFound }
        return await PageSchemeHandler.dynamicResponse(to: request, source: dynamicResources)
    }

    /// Runs `body` as an async function of `arguments` in the page's main world, in whichever engine
    /// shows it, and returns its JSON-compatible result (nil for an exception or no page): WebKit's
    /// `callAsyncJavaScript`, or the Chromium page's ``PageChromiumPage/evaluate(_:)`` of the same
    /// function.
    ///
    /// - Parameters:
    ///   - body: A function body; `return` gives the result, and each argument is a variable.
    ///   - arguments: Named JSON-compatible values (`NSNull` for null).
    /// - Returns: The returned value as Foundation JSON (`String`, `NSNumber`, arrays, dictionaries).
    public func callPageFunction(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        guard !awaitsFirstShow else { return nil } // no document yet; WebKit would launch its process for it
        // MQ12 thaws first: a frozen page cannot answer, and it does not freeze until the answer comes.
        pushes.callStarted()
        defer { pushes.callEnded() }
        // The router envelopes waiting for the frame were sent before it.
        scripts.flush()
        guard let page = chromiumSession?.page else {
            // No engine view yet: a Chromium page on its way has no document to call.
            return try? await webKitPieces?.view.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        }
        let names = arguments.keys.sorted()
        guard let values = try? JSONSerialization.data(withJSONObject: names.map { arguments[$0] ?? NSNull() }, options: [.fragmentsAllowed]),
              let list = String(data: values, encoding: .utf8) else { return nil }
        let expression = "(async function(\(names.joined(separator: ", "))) {\n\(body)\n}).apply(null, \(list))"
        return try? await page.evaluate(expression)
    }

    /// Makes `edit` in the focused editable element of a Chromium page (``PageInputReadiness``).
    private static func apply(_ edit: PageInputReadiness.Edit, token: String?, expectedEpoch: Int?, in page: any PageChromiumPage) async -> Bool {
        let expression = "(function () {\n\(PageInputReadiness.editScript(edit, token: token, expectedEpoch: expectedEpoch))\n})()"
        return (try? await page.evaluate(expression)) as? Bool == true // MQ12 allowed: focus keeps a page from freezing
    }
}
