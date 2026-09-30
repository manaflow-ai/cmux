import AppKit
import CmuxBrowser
import WebKit

/// Receives events for one REPL session: `(name, payload)`; the payload
/// already carries `targetId`.
typealias BrowserReplTabEventSink = @MainActor (_ name: String, _ payload: [String: Any]) -> Void

/// Tabs that REPL sessions are driving, keyed by browser surface id.
///
/// `BrowserPanel`'s UI and download delegates consult this registry: when a
/// session is attached to the panel, dialogs, file choosers, popups and
/// downloads are routed to the session instead of cmux's native UI. Panels
/// without an attachment keep their normal behavior.
@MainActor
final class BrowserReplTabAttachments {
    static let shared = BrowserReplTabAttachments()

    private var attachments: [UUID: BrowserReplTabAttachment] = [:]

    /// The live attachment for `panelID`, if any session is attached.
    func attachment(for panelID: UUID) -> BrowserReplTabAttachment? {
        guard let attachment = attachments[panelID], attachment.isAttached else { return nil }
        return attachment
    }

    /// Attaches `sessionID` to `panel`, creating the attachment on first use.
    @discardableResult
    func attach(
        panel: BrowserPanel,
        sessionID: String,
        sink: @escaping BrowserReplTabEventSink
    ) -> BrowserReplTabAttachment {
        let attachment = attachments[panel.id] ?? BrowserReplTabAttachment(panel: panel)
        attachments[panel.id] = attachment
        attachment.addSink(sessionID: sessionID, sink: sink)
        return attachment
    }

    /// Detaches `sessionID` from every tab.
    func detach(sessionID: String) {
        for (panelID, attachment) in attachments {
            attachment.removeSink(sessionID: sessionID)
            if !attachment.isAttached {
                attachments.removeValue(forKey: panelID)
            }
        }
    }

    /// Detaches everything from a panel that is closing.
    func panelDidClose(_ panelID: UUID) {
        guard let attachment = attachments.removeValue(forKey: panelID) else { return }
        attachment.emit("tab.closed", [:])
        attachment.detachAll()
    }

    /// Session ids attached to `panelID`.
    func sessions(attachedTo panelID: UUID) -> [String] {
        attachments[panelID]?.sessionIDs ?? []
    }
}

/// Per-tab automation state shared by the sessions driving that tab.
@MainActor
final class BrowserReplTabAttachment {
    let panelID: UUID
    weak var panel: BrowserPanel?

    private var sinks: [String: BrowserReplTabEventSink] = [:]
    private var dialogs: [String: (Bool, String?) -> Void] = [:]
    private var fileChoosers: [String: ([URL]?) -> Void] = [:]
    private var nextID = 0
    private var resourceObserver: BrowserReplResourceLoadObserver?
    private var consoleHandler: BrowserReplConsoleMessageHandler?
    private weak var instrumentedWebView: WKWebView?
    private var networkIdleWaiters: [CheckedContinuation<Void, Never>] = []

    /// An automated left-button press and the HTML5 drag it may have started.
    struct DragState {
        let capture: BrowserAutomationDragCapture
        var drop: BrowserAutomationDraggingInfo?
        var operation: NSDragOperation = []
    }

    private var renderHost: BrowserOffscreenRenderHost?
    private weak var renderHostWebView: WKWebView?
    /// The web view whose window occlusion detection is off while attached.
    private weak var occlusionDisabledWebView: WKWebView?
    /// Watches the pane's window becoming key while a mirror stands in for the page.
    private var keyObserver: NSObjectProtocol?
    private var mirrorCaptureInFlight = false
    private var mirrorNeedsCapture = false

    /// Mouse buttons held by automation, for drag event types.
    var mouseState = BrowserReplMouseState()
    /// The drag in progress, between a left press and its release.
    var drag: DragState?
    /// Last automated mouse position in CSS pixels.
    var mousePosition = CGPoint.zero
    /// Per-tab virtual clipboard (`clipboard.read` / `clipboard.write`).
    var clipboardItems: [[String: Any]] = []
    /// Target id of the tab that opened this one, for popups.
    var openerTargetID: String?
    /// Credentials from `user:password@` in URLs a session navigated to, by
    /// `host:port`. HTTP auth challenges in a driven tab answer from these
    /// instead of showing a prompt nobody can answer.
    private var httpCredentials: [String: URLCredential] = [:]

    func rememberCredentials(in url: URL) {
        guard let user = url.user, !user.isEmpty, let host = url.host else { return }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        httpCredentials["\(host.lowercased()):\(port)"] = URLCredential(
            user: user.removingPercentEncoding ?? user,
            password: (url.password ?? "").removingPercentEncoding ?? url.password ?? "",
            persistence: .forSession
        )
    }

    /// The answer to an HTTP authentication challenge in a driven tab: the
    /// URL's credentials once, then the unauthenticated response (a 401
    /// page the session sees) instead of a prompt.
    func answerAuthenticationChallenge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        let space = challenge.protectionSpace
        let httpMethods: Set<String> = [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodDefault,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
        ]
        guard httpMethods.contains(space.authenticationMethod), !space.isProxy() else { return nil }
        let key = "\(space.host.lowercased()):\(space.port)"
        if challenge.previousFailureCount == 0, let credential = httpCredentials[key] {
            return (.useCredential, credential)
        }
        return (.rejectProtectionSpace, nil)
    }
    /// Finished downloads by id.
    private(set) var downloadPaths: [String: String] = [:]
    /// HTTP status of the latest main-document response.
    private(set) var mainDocumentStatus: Int?
    /// Increments on every request start, so `networkidle` can tell a quiet
    /// period from one where requests started and finished.
    private(set) var requestGeneration = 0
    private weak var agentScriptWebView: WKWebView?

    init(panel: BrowserPanel) {
        panelID = panel.id
        self.panel = panel
    }

    var isAttached: Bool { !sinks.isEmpty }
    var sessionIDs: [String] { Array(sinks.keys).sorted() }
    var targetID: String { panelID.uuidString }

    func addSink(sessionID: String, sink: @escaping BrowserReplTabEventSink) {
        let wasAttached = isAttached
        sinks[sessionID] = sink
        instrumentCurrentWebView()
        if !wasAttached {
            panel?.reevaluateHiddenWebViewDiscardScheduling(reason: "browser.repl.attach")
        }
        keepRendering()
    }

    /// Keeps the tab rendering like a foreground page while a session drives
    /// it. `requestAnimationFrame`, timers and `visibilityState` pause in a
    /// hidden WebKit page, and Playwright-style actionability waits for
    /// animation frames. WebKit also treats a page as focused (focus and blur
    /// events, `document.hasFocus()`, `:hover` from mouse moves) only while
    /// its window is key, and it has no switch to override that.
    ///
    /// - A tab shown in a pane of the key window stays in the pane, live.
    /// - A tab no pane shows moves into a render window that lies outside
    ///   every screen and reports itself as key.
    /// - A tab shown in a pane of a window that is not key (the user works in
    ///   another app) moves to that render window too, so input behaves as in
    ///   a focused browser, and a mirror of the page stays in the pane,
    ///   refreshed after every driver call (``pageDidChange()``). The live
    ///   view returns as soon as that window becomes key.
    ///
    /// Occlusion detection is off while attached, so a covered window keeps
    /// rendering. Every move is undone on detach, and when a pane starts
    /// showing the tab (``paneVisibilityDidChange(visible:)``).
    func keepRendering() {
        guard isAttached, let panel else { return }
        _ = panel.restoreDiscardedWebViewIfNeeded(reason: "browser.repl", allowBlankShellHeal: false)
        let webView = panel.webView
        if occlusionDisabledWebView !== webView {
            if let previous = occlusionDisabledWebView { Self.setOcclusionDetection(true, on: previous) }
            Self.setOcclusionDetection(false, on: webView)
            occlusionDisabledWebView = webView
        }
        let shown = panel.isWebViewVisibleInPane
        let paneWindow = renderHostWebView === webView ? renderHost?.paneWindow : webView.window
        if shown, paneWindow?.isKeyWindow == true {
            releaseRenderHost()
            return
        }
        if let renderHost, renderHostWebView === webView, renderHost.hasMirror == shown {
            renderHost.reassertAutomationFocus()
            return
        }
        releaseRenderHost()
        guard panel.mobileBrowserStreamRenderHost == nil,
              !webView.cmuxIsElementFullscreenActiveOrTransitioning else {
            return
        }
        // A shown tab keeps its pane's size, so the page does not reflow.
        let paneSize = webView.bounds.size
        let viewport = shown && panel.viewportModel.viewport == nil && paneSize.width > 1 && paneSize.height > 1
            ? paneSize
            : Self.renderViewportSize(panel: panel)
        let host = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: viewport,
            reportsKeyWindow: true,
            placement: .offAllScreens,
            mirrorsPane: shown
        )
        renderHost = host
        renderHostWebView = webView
        if shown, let window = host.paneWindow {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseRenderHost() }
            }
            pageDidChange()
        }
    }

    /// Keeps the tab rendering (``keepRendering()``) and waits until WebKit
    /// has applied the resulting window, visibility and focus state, so the
    /// page is visible and focused before the caller sends input. A tab that
    /// just moved into the render window gets that state asynchronously;
    /// keys sent before it arrive reach an unfocused page.
    func renderingSettled() async {
        keepRendering()
        guard let webView = panel?.webView else { return }
        await BrowserReplNativeInput.afterActivityStateUpdate(webView)
    }

    /// Called by the panel when a pane starts or stops showing this tab. A
    /// shown tab leaves the render window at once, so the pane is never blank.
    func paneVisibilityDidChange(visible: Bool) {
        guard visible else { return }
        releaseRenderHost()
    }

    /// Refreshes the pane's mirror after a driver call may have changed the
    /// page. One capture runs at a time; a call during it asks for one more.
    func pageDidChange() {
        guard let host = renderHost, host.hasMirror, let webView = renderHostWebView else { return }
        guard !mirrorCaptureInFlight else {
            mirrorNeedsCapture = true
            return
        }
        mirrorCaptureInFlight = true
        mirrorNeedsCapture = false
        webView.takeSnapshot(with: nil) { [weak self, weak host] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mirrorCaptureInFlight = false
                if let image, let host, host === self.renderHost { host.updateMirror(image) }
                if self.mirrorNeedsCapture { self.pageDidChange() }
            }
        }
    }

    /// Whether the pane shows a mirror of the page instead of the page.
    var isMirroringPane: Bool { renderHost?.hasMirror == true }

    /// Viewport of a hidden driven tab: Playwright's default page size, so
    /// results do not depend on whatever window last hosted the tab.
    static let hiddenTabViewportSize = NSSize(width: 1280, height: 800)

    /// The viewport a hidden driven tab renders at: an explicit
    /// `setViewportSize`, else ``hiddenTabViewportSize``.
    private static func renderViewportSize(panel: BrowserPanel) -> NSSize {
        if let viewport = panel.viewportModel.viewport { return viewport.size }
        return hiddenTabViewportSize
    }

    /// Whether the tab currently renders in the off-screen render window.
    var isInRenderWindow: Bool { renderHost != nil }

    private func releaseRenderHost() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        guard let host = renderHost else { return }
        renderHost = nil
        if let webView = renderHostWebView, webView === panel?.webView {
            host.restore()
            // The pane's portal skipped this web view while the render window
            // held it; bring it back into the pane now.
            BrowserWindowPortalRegistry.refresh(webView: webView, reason: "browserReplRelease")
        } else {
            host.abandon()
        }
        renderHostWebView = nil
    }

    private static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(webView.method(for: selector), to: Setter.self)
        setter(webView, selector, enabled)
    }

    func removeSink(sessionID: String) {
        sinks.removeValue(forKey: sessionID)
        if sinks.isEmpty { detachAll() }
    }

    /// Releases held dialogs and choosers and removes page instrumentation.
    func detachAll() {
        sinks.removeAll()
        // Playwright dismisses dialogs nobody handles; do the same so a page
        // is never left blocked on a dialog after its session goes away.
        for respond in dialogs.values { respond(false, nil) }
        dialogs.removeAll()
        for respond in fileChoosers.values { respond(nil) }
        fileChoosers.removeAll()
        uninstrument()
        releaseRenderHost()
        if let webView = occlusionDisabledWebView {
            Self.setOcclusionDetection(true, on: webView)
            occlusionDisabledWebView = nil
        }
        panel?.reevaluateHiddenWebViewDiscardScheduling(reason: "browser.repl.detach")
        if let cmuxWebView = panel?.webView as? CmuxWebView {
            cmuxWebView.automationDragCapture = nil
            drag = nil
            cmuxWebView.releaseBrowserReplModifiers()
        }
        mouseState.reset()
        let waiters = networkIdleWaiters
        networkIdleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func emit(_ name: String, _ payload: [String: Any]) {
        var body = payload
        body["targetId"] = targetID
        for sink in sinks.values { sink(name, body) }
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    // MARK: - Instrumentation

    /// Installs network and console reporting on the panel's current web
    /// view. Called on attach and again when the panel replaces its web view.
    func instrumentCurrentWebView() {
        guard let webView = panel?.webView, webView !== instrumentedWebView, isAttached else { return }
        uninstrument()
        instrumentedWebView = webView
        let observer = BrowserReplResourceLoadObserver { [weak self] event, payload in
            guard let self else { return }
            if event == "request" { self.requestGeneration += 1 }
            if event == "response", payload["resourceType"] as? String == "document",
               payload["isMainFrame"] as? Bool ?? true,
               let status = payload["status"] as? Int {
                self.mainDocumentStatus = status
            }
            self.emit(event, payload)
        }
        observer.onInflightChange = { [weak self] count in
            guard let self, count == 0 else { return }
            let waiters = self.networkIdleWaiters
            self.networkIdleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        if observer.install(on: webView) {
            resourceObserver = observer
        }
        let handler = BrowserReplConsoleMessageHandler { [weak self] event, payload in
            self?.emit(event, payload)
        }
        webView.configuration.userContentController.add(
            handler,
            contentWorld: .page,
            name: BrowserReplConsoleMessageHandler.name
        )
        consoleHandler = handler
        webView.configuration.userContentController.add(
            BrowserReplAgentPresenceHandler(),
            contentWorld: BrowserReplAgentWorld.world,
            name: BrowserReplAgentPresenceHandler.name
        )
    }

    private func uninstrument() {
        resourceObserver?.uninstall()
        resourceObserver = nil
        if consoleHandler != nil, let webView = instrumentedWebView {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserReplConsoleMessageHandler.name,
                contentWorld: .page
            )
        }
        if let webView = instrumentedWebView {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserReplAgentPresenceHandler.name,
                contentWorld: BrowserReplAgentWorld.world
            )
        }
        consoleHandler = nil
        instrumentedWebView = nil
    }

    /// Adds the page agent as a document-start user script in every frame's
    /// agent world, so documents loaded from now on have it before their own
    /// scripts run. Frames already loaded get it on their first evaluation.
    func installAgentUserScriptIfNeeded(source: String) {
        guard let webView = panel?.webView, webView !== agentScriptWebView else { return }
        agentScriptWebView = webView
        // The script stays in the controller after the session ends; the
        // guard makes it a no-op once the agent-world handler is removed.
        let guarded = """
        if (globalThis.webkit && webkit.messageHandlers && webkit.messageHandlers.\(BrowserReplAgentPresenceHandler.name)) {
        \(source)
        }
        """
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: guarded,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: BrowserReplAgentWorld.world
        ))
    }

    /// Requests in flight, or `nil` when the resource load SPI is unavailable.
    var inflightRequestCount: Int? {
        resourceObserver?.inflightCount
    }

    /// Resumes when no request is in flight (immediately if none is).
    func waitForNoInflightRequests() async {
        guard let observer = resourceObserver, observer.inflightCount > 0 else { return }
        await withCheckedContinuation { networkIdleWaiters.append($0) }
    }

    // MARK: - Dialogs

    /// Routes a JavaScript dialog to the attached sessions.
    /// - Returns: `false` when no session is attached; the caller shows its native UI.
    func handleDialog(
        type: String,
        message: String,
        defaultValue: String?,
        respond: @escaping (Bool, String?) -> Void
    ) -> Bool {
        guard isAttached else { return false }
        let id = makeID("d")
        dialogs[id] = respond
        emit("dialog.opened", [
            "dialogId": id,
            "type": type,
            "message": message,
            "defaultValue": defaultValue ?? "",
        ])
        return true
    }

    /// Whether a JavaScript dialog is waiting for `dialog.respond`; page
    /// script is blocked until it is answered.
    var hasPendingDialog: Bool { !dialogs.isEmpty }

    /// The last `tab.info` answered from the page, reused while a dialog blocks it.
    var lastInfo: [String: Any]?

    func respondToDialog(id: String, accept: Bool, promptText: String?) -> Bool {
        guard let respond = dialogs.removeValue(forKey: id) else { return false }
        respond(accept, promptText)
        return true
    }

    // MARK: - File choosers

    /// Routes a file input's open panel to the attached sessions.
    func handleOpenPanel(
        allowsMultiple: Bool,
        frame: WKFrameInfo,
        respond: @escaping ([URL]?) -> Void
    ) -> Bool {
        guard isAttached else { return false }
        let id = makeID("c")
        fileChoosers[id] = respond
        let frameID = frame.isMainFrame ? nil : BrowserReplFrameTree.frameID(of: frame)
        Task { @MainActor [weak self] in
            let element = await self?.chooserElementHandle(in: frame)
            self?.emit("filechooser.opened", [
                "chooserId": id,
                "frameId": frameID ?? NSNull(),
                "element": element ?? NSNull(),
                "multiple": allowsMultiple,
            ])
        }
        return true
    }

    func respondToFileChooser(id: String, files: [URL]?) -> Bool {
        guard let respond = fileChoosers.removeValue(forKey: id) else { return false }
        respond(files)
        return true
    }

    /// The agent handle of the file input that opened the chooser.
    private func chooserElementHandle(in frame: WKFrameInfo) async -> String? {
        guard let webView = panel?.webView else { return nil }
        let source = "const a = globalThis[\(BrowserReplRuntimeBundle.agentGlobalKeyExpression)]; return a ? a.chooserHandle() : null;"
        let value = try? await webView.callAsyncJavaScript(
            source,
            arguments: [:],
            in: frame,
            contentWorld: BrowserReplAgentWorld.world
        )
        return value as? String
    }

    // MARK: - Popups

    /// Opens a page-requested window as a new background browser surface next
    /// to this tab, reported to the sessions as `tab.created`.
    /// Opens a page-opened window as a background tab whose web view WebKit
    /// created the page from (`createWebViewWith`), returning that web view.
    /// `nil` when no tab could be opened; `.opened(nil)` when the tab opened
    /// but loads the URL itself (the web view could not be adopted).
    enum PopupAdoption {
        case opened(WKWebView?)
    }

    func adoptPopup(request: URLRequest, configuration: WKWebViewConfiguration) -> PopupAdoption? {
        guard isAttached, let panel,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              let pane = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        let url = request.url ?? URL(string: "about:blank")!
        BrowserPanel.configureWebViewConfiguration(configuration, websiteDataStore: panel.websiteDataStore)
        let webView = CmuxWebView(frame: .zero, configuration: configuration, host: CmuxWebViewAppHost())
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = panel.webView.pageZoom
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.applyBrowserUserAgentPolicy(for: url)
        BrowserPanel.pendingPopupWebView = (url, webView)
        defer { BrowserPanel.pendingPopupWebView = nil }
        guard let created = workspace.newBrowserSurface(
            inPane: pane,
            url: url,
            focus: false,
            preferredProfileID: panel.profileID,
            creationPolicy: .automationPreload,
            websiteDataStore: panel.websiteDataStore
        ) else {
            return nil
        }
        announcePopup(created, url: url)
        return .opened(created.webView === webView ? webView : nil)
    }

    private func announcePopup(_ created: BrowserPanel, url: URL) {
        var child: BrowserReplTabAttachment?
        for (sessionID, sink) in sinks {
            child = BrowserReplTabAttachments.shared.attach(panel: created, sessionID: sessionID, sink: sink)
        }
        child?.openerTargetID = targetID
        for sink in sinks.values {
            sink("tab.created", [
                "targetId": created.id.uuidString,
                "openerTargetId": targetID,
                "url": url.absoluteString,
            ])
        }
    }

    func handlePopup(request: URLRequest) -> Bool {
        guard isAttached, let panel, let url = request.url,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              let pane = workspace.paneId(forPanelId: panel.id) else {
            return false
        }
        guard let created = workspace.newBrowserSurface(
            inPane: pane,
            url: url,
            focus: false,
            creationPolicy: .automationPreload
        ) else {
            return false
        }
        var child: BrowserReplTabAttachment?
        for (sessionID, sink) in sinks {
            child = BrowserReplTabAttachments.shared.attach(panel: created, sessionID: sessionID, sink: sink)
        }
        child?.openerTargetID = targetID
        for sink in sinks.values {
            sink("tab.created", [
                "targetId": created.id.uuidString,
                "openerTargetId": targetID,
                "url": url.absoluteString,
            ])
        }
        return true
    }

    // MARK: - Downloads

    /// Downloads started while a session is attached stay in cmux's temporary
    /// download directory, so `download.path()` can read them.
    var keepsDownloadsInTemporaryDirectory: Bool { isAttached }

    func downloadDidStart(id: String, url: URL?, suggestedFilename: String) {
        emit("download.started", [
            "downloadId": id,
            "url": url?.absoluteString ?? "",
            "suggestedFilename": suggestedFilename,
        ])
    }

    func downloadDidFinish(id: String, path: String?, error: String?) {
        if let path { downloadPaths[id] = path }
        var payload: [String: Any] = ["downloadId": id]
        if let path { payload["path"] = path }
        if let error { payload["error"] = error }
        emit("download.finished", payload)
    }
}

/// The isolated content world the REPL page agent lives in.
///
/// The world is configured to see closed shadow roots
/// (`_WKContentWorldConfiguration.allowAccessToClosedShadowRoots`, the switch
/// WebKit gives web extension worlds): in it `element.shadowRoot` returns a
/// closed root too, so the snapshot, refs and Playwright's selector engines
/// reach closed components the way an accessibility tree does. Page scripts
/// in other worlds still see `null`. Without the SPI the world is a plain
/// named world and closed roots stay hidden.
enum BrowserReplAgentWorld {
    static let name = "cmux-agent"

    @MainActor static let world: WKContentWorld = configuredWorld() ?? .world(name: name)

    @MainActor private static func configuredWorld() -> WKContentWorld? {
        guard let configurationClass = NSClassFromString("_WKContentWorldConfiguration") as? NSObject.Type else {
            return nil
        }
        let configuration = configurationClass.init()
        let setName = NSSelectorFromString("setName:")
        let setClosed = NSSelectorFromString("setAllowAccessToClosedShadowRoots:")
        let factory = NSSelectorFromString("_worldWithConfiguration:")
        guard configuration.responds(to: setName), configuration.responds(to: setClosed),
              (WKContentWorld.self as AnyObject).responds(to: factory) else {
            return nil
        }
        configuration.setValue(name, forKey: "name")
        configuration.setValue(true, forKey: "allowAccessToClosedShadowRoots")
        return (WKContentWorld.self as AnyObject).perform(factory, with: configuration)?
            .takeUnretainedValue() as? WKContentWorld
    }
}

/// Receives console and page error reports from the page telemetry script.
@MainActor
final class BrowserReplConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxReplConsole"

    private let emit: (String, [String: Any]) -> Void

    init(emit: @escaping (String, [String: Any]) -> Void) {
        self.emit = emit
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "console":
            emit("console", [
                "type": body["type"] as? String ?? "log",
                "text": body["text"] as? String ?? "",
            ])
        case "pageerror":
            emit("pageerror", [
                "message": body["message"] as? String ?? "",
                "stack": body["stack"] as? String ?? "",
            ])
        default:
            break
        }
    }
}

/// Marks, in the agent world, that a REPL session is attached; the agent's
/// document-start script installs itself only while this handler exists.
@MainActor
final class BrowserReplAgentPresenceHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxReplAgent"

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {}
}
