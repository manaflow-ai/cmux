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
    /// animation frames.
    ///
    /// - A tab shown in a pane stays in that pane and keeps rendering live
    ///   there; occlusion detection is off while attached, so a covered
    ///   window keeps running the page.
    /// - A tab no pane shows moves into a render window that lies outside
    ///   every screen and reports itself as key (pages in a non-key window
    ///   get no mouse moves, so no `:hover`). It returns to its pane as soon
    ///   as the pane shows it (``paneVisibilityDidChange(visible:)``), and on
    ///   detach.
    func keepRendering() {
        guard isAttached, let panel else { return }
        _ = panel.restoreDiscardedWebViewIfNeeded(reason: "browser.repl", allowBlankShellHeal: false)
        let webView = panel.webView
        if occlusionDisabledWebView !== webView {
            if let previous = occlusionDisabledWebView { Self.setOcclusionDetection(true, on: previous) }
            Self.setOcclusionDetection(false, on: webView)
            occlusionDisabledWebView = webView
        }
        if panel.isWebViewVisibleInPane {
            releaseRenderHost()
            return
        }
        if let renderHost, renderHostWebView === webView {
            renderHost.reassertAutomationFocus()
            return
        }
        renderHost?.abandon()
        renderHost = nil
        renderHostWebView = nil
        guard panel.mobileBrowserStreamRenderHost == nil,
              !webView.cmuxIsElementFullscreenActiveOrTransitioning else {
            return
        }
        renderHost = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: Self.renderViewportSize(panel: panel),
            reportsKeyWindow: true,
            placement: .offAllScreens
        )
        renderHostWebView = webView
    }

    /// Called by the panel when a pane starts or stops showing this tab. A
    /// shown tab leaves the render window at once, so the pane is never blank.
    func paneVisibilityDidChange(visible: Bool) {
        guard visible else { return }
        releaseRenderHost()
    }

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
enum BrowserReplAgentWorld {
    @MainActor static let world = WKContentWorld.world(name: "cmux-agent")
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
