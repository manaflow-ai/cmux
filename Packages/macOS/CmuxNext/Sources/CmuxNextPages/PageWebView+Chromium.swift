public import AppKit
import CmuxNextDesign
import CmuxNextErrorJournal
import Foundation

// Chromium mode (`browser.defaultEngine` is `chromium`, ``PageEnginePolicy``): the page shows in a
// Chromium page from ``PageWebView/chromiumHosting``, over the same router, theme and scripts. The
// WebKit view stays as an unloaded, hidden subview, so a page that fails in Chromium reopens in
// WebKit at once (``fallBackToWebKit(_:)``) and WebKit-only hosts keep compiling.
extension PageWebView {
    /// The handlers the page scripts post to without a reply, in Chromium mode.
    static let chromiumFireAndForget = [
        PagePaintProbe.handlerName, PageInputReadiness.handlerName, ConsoleErrorCapture.handlerName,
        PageChromiumDocumentScripts.navigateHandler,
    ]

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
        guard let hosting else {
            // No Chromium host (a build or test without one): a page that could not run there keeps
            // its own reason, any other one is on WebKit because Chromium is missing.
            return PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: descriptor, options: options)
        }
        return PageEnginePolicy(preference: hosting.preference, chromiumAvailable: hosting.isAvailable,
                                chromiumServes: hosting.serves(descriptor)).decide(for: descriptor, options: options)
    }

    /// The view that takes the keyboard when the page is focused: Chromium's view or the WebKit view.
    public var focusView: NSView { chromiumSession?.page.contentView ?? webView }

    /// The page zoom both engines show: `uiScale` times ``additionalZoom``.
    var pageZoom: Double { Double(DesignSettings.shared.uiScale) * additionalZoom }

    // MARK: Engine-neutral document calls

    /// Runs `script` in the page's main frame in whichever engine shows it.
    func evaluateInPage(_ script: String) {
        scriptTarget.evaluate(script)
    }

    /// Loads `url` (a document of this page) in whichever engine shows it.
    func loadDocument(_ url: URL) {
        if let chromiumSession { chromiumSession.page.load(url) } else { webView.load(URLRequest(url: url)) }
    }

    /// Reloads the document in whichever engine shows it.
    func reloadDocument() {
        if let chromiumSession { chromiumSession.page.reload() } else { webView.reload() }
    }

    // MARK: Start

    /// Starts the Chromium page and loads `url` in it; falls back to WebKit when that fails or the
    /// page does not reach the host in time.
    func startChromium(url: URL, hosting: any PageChromiumHosting) {
        webView.isHidden = true
        let scripts = PageChromiumDocumentScripts(controller: webView.configuration.userContentController)
        let descriptor = descriptor
        chromiumStart = Task { [weak self] in
            let page: any PageChromiumPage
            do {
                page = try await hosting.makePage(descriptor)
            } catch {
                self?.fallBackToWebKit(.chromiumFailed, detail: "\(error)")
                return
            }
            guard let self, self.chromiumStart?.isCancelled == false else {
                page.close()
                return
            }
            await self.attachChromium(page, scripts: scripts, url: url)
        }
    }

    private func attachChromium(_ page: any PageChromiumPage, scripts: PageChromiumDocumentScripts, url: URL) async {
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: Self.chromiumFireAndForget)
        let session = PageChromiumSession(page: page, bridge: bridge)
        page.onEvent = { [weak self] event in self?.chromiumEvent(event) }
        do {
            for (method, params) in ChromiumPageHostBridge.setupCalls(handlers: Self.chromiumFireAndForget,
                                                                       documentScripts: scripts.sources) {
                _ = try await page.devTools(method, params: params)
            }
        } catch {
            session.end()
            fallBackToWebKit(.chromiumFailed, detail: "setup: \(error)")
            return
        }
        guard chromiumStart?.isCancelled == false else {
            session.end()
            return
        }
        bridge.install { [weak self] message in await self?.receive(message) }
        bridge.onMessage = { [weak self] name, body in self?.chromiumMessage(name, body: body) }
        bridge.onFirstMessage = { [weak session] in
            session?.deadline?.cancel()
            session?.deadline = nil
        }
        inputReadiness.inserter = { [weak page] text in
            guard let page else { return false }
            return await Self.insert(text, in: page)
        }
        chromiumSession = session
        scriptTarget.bridge = bridge
        bridge.evaluate(DesignSettings.shared.interfaceScaleScript)
        page.setZoom(pageZoom)
        page.contentView.frame = bounds
        page.contentView.autoresizingMask = [.width, .height]
        addSubview(page.contentView)
        page.setVisible(window != nil && !isHiddenOrHasHiddenAncestor)
        page.load(url)
        let wait = chromiumDeadline
        let sleep = chromiumSleep
        // concurrency-allow: a bounded, cancellable deadline; the first message cancels it.
        session.deadline = Task { [weak self] in
            guard (try? await sleep(wait)) != nil, !Task.isCancelled else { return }
            self?.fallBackToWebKit(.chromiumFailed, detail: "no message from the page within \(wait)")
        }
        if shouldFocusOnAttach == false, window?.firstResponder === webView { focusPage() }
    }

    /// Chromium failed for this page: it reopens in WebKit, at the route it showed.
    func fallBackToWebKit(_ reason: PageWebKitReason, detail: String) {
        chromiumStart?.cancel()
        chromiumStart = nil
        logger.error("page \(self.descriptor.id, privacy: .public) reopens in WebKit: \(detail, privacy: .public)")
        chromiumSession?.end()
        chromiumSession = nil
        inputReadiness.inserter = nil
        scriptTarget.bridge = bridge
        engineDecision = .webKit(reason)
        webView.isHidden = false
        router.reset()
        loaded = false
        webView.load(URLRequest(url: descriptor.url(route: route)))
    }

    /// Ends Chromium mode for good (the page closed).
    func endChromium() {
        chromiumStart?.cancel()
        chromiumStart = nil
        chromiumSession?.end()
        chromiumSession = nil
        inputReadiness.inserter = nil
    }

    // MARK: Events

    private func chromiumEvent(_ event: PageChromiumEvent) {
        guard let chromiumSession else { return }
        switch event {
        case .devTools(let json):
            guard !chromiumSession.bridge.receive(devToolsMessage: json),
                  let event = ChromiumPageHostWire.documentEvent(json) else { return }
            chromiumEvent(event)
        case .committed(let url):
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
        case .finished:
            documentFinished()
        case .crashed:
            contentProcessTerminated()
        case .ended:
            fallBackToWebKit(.chromiumFailed, detail: "the Chromium browser ended")
        case .openRequested(let url):
            openOutside(url, modifiers: [])
        }
    }

    private func chromiumMessage(_ name: String, body: Any) {
        switch name {
        case PagePaintProbe.handlerName:
            notePainted()
        case PageInputReadiness.handlerName:
            inputReadiness.receive(body)
        case ConsoleErrorCapture.handlerName:
            ConsoleErrorCapture(page: descriptor.id).record(body)
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
            break
        }
    }

    /// Opens a link that leaves the page as WebKit's policy does (``onOpenExternal`` or the shared rule).
    private func openOutside(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        externalLinkModifiers = modifiers
        let other = LinkRouter.isOtherTarget(modifiers)
        (onOpenExternal ?? { LinkRouter.shared.open($0, otherTarget: other) })(url)
    }

    /// Types `text` into the focused editable element of a Chromium page (``PageInputReadiness``).
    private static func insert(_ text: String, in page: any PageChromiumPage) async -> Bool {
        let expression = "(function (text) {\n\(PageInputReadiness.insertScript)\n})(\(JSONValue.string(text).compactText))"
        guard let json = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "returnByValue": true]) else {
            return false
        }
        return ChromiumPageHostWire.evaluationIsTrue(json)
    }
}
