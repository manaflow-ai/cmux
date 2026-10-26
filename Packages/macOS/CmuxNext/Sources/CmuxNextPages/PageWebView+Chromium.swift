public import AppKit
import CmuxNextDesign
import CmuxNextErrorJournal
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

// Chromium mode (`browser.defaultEngine` is `chromium`, ``PageEnginePolicy``): the page shows in a
// Chromium page from ``PageWebView/chromiumHosting``, over the same router, theme and scripts. The
// WebKit view stays as an unloaded, hidden subview, so a page that fails in Chromium reopens in
// WebKit at once (``fallBackToWebKit(_:)``) and WebKit-only hosts keep compiling.
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
        guard let hosting else {
            // No Chromium host (a build or test without one): a page that could not run there keeps
            // its own reason, any other one is on WebKit because Chromium is missing.
            return PageEnginePolicy(preference: .chromium, chromiumAvailable: false).decide(for: descriptor, options: options)
        }
        // A live web override reaches only WebKit pages; deciding also arms its watch, so a launch
        // whose first page is a Chromium one still reads web-dev.json.
        WebDevOverrideWatcher.shared.start()
        return PageEnginePolicy(preference: hosting.preference, chromiumAvailable: hosting.isAvailable,
                                chromiumServes: hosting.serves(descriptor),
                                liveWebOverride: WebDevOverride.current.isActive).decide(for: descriptor, options: options)
    }

    /// The view that takes the keyboard when the page is focused: Chromium's view or the WebKit view.
    public var focusView: NSView { chromiumSession?.page.contentView ?? webView }

    /// The Chromium page that shows the page now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { chromiumSession?.page }

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
    func reloadPage() {
        if let chromiumSession { chromiumSession.page.reload() } else { webView.reload() }
    }

    // MARK: Start

    /// Starts the Chromium page and loads the document at ``route`` in it (as it stands once the page
    /// exists, so an ``open(route:)`` meanwhile wins); falls back to WebKit when that fails or the
    /// page does not reach the host in time.
    func startChromium(hosting: any PageChromiumHosting) {
        #if DEBUG || CMUX_BENCH_HOOKS
        traceMark(.chromiumStart)
        #endif
        webView.isHidden = true
        let scripts = PageChromiumDocumentScripts(controller: webView.configuration.userContentController)
        let descriptor = descriptor
        #if DEBUG || CMUX_BENCH_HOOKS
        let traced = ChatOpenTrace.shared.isTraced(page: self)
        #endif
        chromiumStart = Task { [weak self] in
            let page: any PageChromiumPage
            do {
                #if DEBUG || CMUX_BENCH_HOOKS
                ChatOpenTrace.shared.makingTracedPage = traced
                #endif
                page = try await hosting.makePage(descriptor)
            } catch {
                self?.fallBackToWebKit(.chromiumFailed, detail: "\(error)")
                return
            }
            guard let self, self.chromiumStart?.isCancelled == false else {
                page.close()
                return
            }
            #if DEBUG || CMUX_BENCH_HOOKS
            traceMark(.browserCreated)
            #endif
            await self.attachChromium(page, scripts: scripts)
        }
    }

    private func attachChromium(_ page: any PageChromiumPage, scripts: PageChromiumDocumentScripts) async {
        let handlers = Self.chromiumFireAndForget + chromiumMessageHandlers.keys.sorted()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: handlers)
        let session = PageChromiumSession(page: page, bridge: bridge, clock: chromiumClock)
        page.onEvent = { [weak self] event in self?.chromiumEvent(event) }
        page.resources = { [weak self] url in await self?.chromiumResource(url) ?? .notFound }
        do {
            for (method, params) in ChromiumPageHostBridge.setupCalls(handlers: handlers,
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
        #if DEBUG || CMUX_BENCH_HOOKS
        traceMark(.setupDone)
        #endif
        bridge.install { [weak self] message in await self?.receive(message) }
        bridge.onMessage = { [weak self] name, body in self?.chromiumMessage(name, body: body) }
        bridge.onFirstMessage = { [weak session] in session?.deadline.cancel() }
        inputReadiness.editor = { [weak self, weak page] edit, expectedEpoch in
            guard let page else { return false }
            return await Self.apply(edit, token: self?.inputReadiness.editToken, expectedEpoch: expectedEpoch, in: page)
        }
        chromiumSession = session
        scriptTarget.bridge = bridge
        bridge.evaluate(DesignSettings.shared.interfaceScaleScript)
        page.setZoom(pageZoom)
        // The WebKit page draws no background (`drawsBackground` off): the Chromium page neither.
        page.setSeeThrough(true)
        page.contentView.frame = bounds
        page.contentView.autoresizingMask = [.width, .height]
        addSubview(page.contentView)
        applyNativeRects()
        page.setVisible(window != nil && !isHiddenOrHasHiddenAncestor)
        #if DEBUG || CMUX_BENCH_HOOKS
        traceMark(.navigationStart)
        #endif
        page.load(descriptor.url(route: route))
        let wait = chromiumDeadline
        // The page's first message cancels the deadline (onFirstMessage); ending the session too.
        session.deadline.schedule(after: wait) { @MainActor [weak self, weak session] in
            guard let self, let session, self.chromiumSession === session else { return }
            self.fallBackToWebKit(.chromiumFailed, detail: "no message from the page within \(wait)")
        }
        if shouldFocusOnAttach == false, window?.firstResponder === webView { focusPage() }
    }

    /// Chromium failed for this page: it reopens in WebKit, at the route it showed.
    func fallBackToWebKit(_ reason: PageWebKitReason, detail: String) {
        // A Chromium start that fails after the tab closed: the retired web view stays unloaded.
        guard !isClosed else { return }
        chromiumStart?.cancel()
        chromiumStart = nil
        logger.error("page \(self.descriptor.id, privacy: .public) reopens in WebKit: \(detail, privacy: .public)")
        chromiumSession?.end()
        chromiumSession = nil
        chromiumUserEventUptime = nil
        chromiumDragFile = nil
        inputReadiness.editor = nil
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
        inputReadiness.editor = nil
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
        case .filesDragged(let urls):
            filesDragged(urls)
        case .userInput(let uptime):
            chromiumUserInput(at: uptime)
        case .contextMenu(let request):
            showChromiumMenu(request)
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
        chromiumSession?.bridge.evaluate("window.__cmuxHostDrop && window.__cmuxHostDrop(\(url != nil))")
    }

    /// The page script handed a drop over. Only the file of a real drag the host took opens, once,
    /// and only soon after it entered: page script can post this message but cannot name a file.
    private func hostDropped() {
        guard let pending = chromiumDragFile else { return }
        chromiumDragFile = nil
        guard now().timeIntervalSince(pending.at) < Self.chromiumDropWindow, let fileDrop else { return }
        noteTouch()
        fileDrop.open(pending.url)
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
    /// `callAsyncJavaScript`, or a Chromium `Runtime.evaluate` of the same function.
    ///
    /// - Parameters:
    ///   - body: A function body; `return` gives the result, and each argument is a variable.
    ///   - arguments: Named JSON-compatible values (`NSNull` for null).
    /// - Returns: The returned value as Foundation JSON (`String`, `NSNumber`, arrays, dictionaries).
    public func callPageFunction(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        guard let page = chromiumSession?.page else {
            return try? await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        }
        let names = arguments.keys.sorted()
        guard let values = try? JSONSerialization.data(withJSONObject: names.map { arguments[$0] ?? NSNull() }, options: [.fragmentsAllowed]),
              let list = String(data: values, encoding: .utf8) else { return nil }
        let expression = "(async function(\(names.joined(separator: ", "))) {\n\(body)\n}).apply(null, \(list))"
        guard let json = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "awaitPromise": true, "returnByValue": true]),
              let object = ChromiumPageHostWire.object(json), object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any] else { return nil }
        return result["value"]
    }

    /// Makes `edit` in the focused editable element of a Chromium page (``PageInputReadiness``).
    private static func apply(_ edit: PageInputReadiness.Edit, token: String?, expectedEpoch: Int?, in page: any PageChromiumPage) async -> Bool {
        let expression = "(function () {\n\(PageInputReadiness.editScript(edit, token: token, expectedEpoch: expectedEpoch))\n})()"
        guard let json = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "returnByValue": true]) else {
            return false
        }
        return ChromiumPageHostWire.evaluationIsTrue(json)
    }
}
