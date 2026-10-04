import AppKit
import CmuxBrowser
import WebKit

/// Receives events for one REPL session: `(name, payload)`; the payload
/// already carries `targetId`.
typealias BrowserReplTabEventSink = @MainActor (_ name: String, _ payload: [String: Any]) -> Void

/// Tabs that REPL sessions are driving, keyed by browser surface id.
///
/// `BrowserPanel`'s UI and download delegates consult this registry: in a tab
/// a session created, dialogs, file choosers, popups and downloads are routed
/// to the session instead of cmux's native UI. A user's tab that a session
/// only drives keeps that UI for every event the session has no handler for
/// (``BrowserReplTabOwnership``). Panels without an attachment keep their
/// normal behavior.
@MainActor
final class BrowserReplTabAttachments {
    static let shared = BrowserReplTabAttachments()

    private var attachments: [UUID: BrowserReplTabAttachment] = [:]
    /// Each session's `session.configure` options and domain-policy rule
    /// list. A tab carries those of the session that created it
    /// (``BrowserReplTabAttachment/contextOptions``).
    private var sessionContexts: [String: BrowserReplContextOptions] = [:]
    /// Secrets sessions typed into tabs, by tab, masked for every other
    /// session's reads until the tab closes (``BrowserReplTypedSecrets``).
    var typedSecrets = BrowserReplTypedSecrets()

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

    /// Sets `sessionID`'s browser-context options and puts them on the
    /// tabs that carry them: the tabs that session created.
    func setContext(_ options: BrowserReplContextOptions, forSession sessionID: String) {
        sessionContexts[sessionID] = options
        for attachment in attachments(forSession: sessionID) { attachment.applyContextToWebView() }
    }

    /// `sessionID`'s browser-context options, if it set any.
    func context(forSession sessionID: String) -> BrowserReplContextOptions? {
        sessionContexts[sessionID]
    }

    /// Detaches `sessionID` from every tab.
    func detach(sessionID: String) {
        sessionContexts.removeValue(forKey: sessionID)
        typedSecrets.sessionLeft(sessionID)
        for (panelID, attachment) in attachments {
            attachment.removeSink(sessionID: sessionID)
            if !attachment.isAttached {
                attachments.removeValue(forKey: panelID)
            }
        }
    }

    /// Detaches everything from a panel that is closing.
    func panelDidClose(_ panelID: UUID) {
        typedSecrets.tabClosed(panelID.uuidString)
        guard let attachment = attachments.removeValue(forKey: panelID) else { return }
        attachment.emit("tab.closed", [:])
        attachment.detachAll()
    }

    /// Live attachments `sessionID` is attached to.
    func attachments(forSession sessionID: String) -> [BrowserReplTabAttachment] {
        attachments.values.filter { $0.sessionIDs.contains(sessionID) }
    }

    /// Session ids attached to `panelID`.
    func sessions(attachedTo panelID: UUID) -> [String] {
        attachments[panelID]?.sessionIDs ?? []
    }

    /// The page clipboard guard with `Resources/browser-repl/page-clipboard.js`,
    /// which the driver loads before it opens a session's first tab.
    var pageClipboard: BrowserReplPageClipboard?

    /// The live attachment whose panel shows `webView`.
    func attachment(showing webView: WKWebView) -> BrowserReplTabAttachment? {
        attachments.values.first { $0.isAttached && $0.panel?.webView === webView }
    }
}

/// Per-tab automation state shared by the sessions driving that tab.
@MainActor
final class BrowserReplTabAttachment {
    let panelID: UUID
    weak var panel: BrowserPanel?

    private var sinks: [String: BrowserReplTabEventSink] = [:]
    /// Dialogs and file choosers waiting for the session each was routed
    /// to; only that session answers one.
    private var dialogs = BrowserReplRoutedRequests<(Bool, String?) -> Void>()
    /// Each chooser's responder and the frame it opened from.
    private var fileChoosers = BrowserReplRoutedRequests<(respond: ([URL]?) -> Void, frame: WKFrameInfo)>()
    private var nextID = 0
    private var resourceObserver: BrowserReplResourceLoadObserver?
    private var consoleHandler: BrowserReplConsoleMessageHandler?
    private weak var instrumentedWebView: WKWebView?
    /// Whether a web view of this tab was instrumented while attached.
    private var hasInstrumentedWebView = false
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
    /// Keys held by automation, released when the last session leaves.
    var heldKeys = BrowserReplHeldKeys()
    /// The session whose press is in progress: from its button down to its
    /// button up no other session's mouse event reaches the page, so two
    /// sessions clicking one tab at once make two clicks, not one. Another
    /// session waits at most 10 s for the press to end.
    private let pointer = BrowserReplPointerOwner()

    func waitForPointer(sessionID: String) async throws {
        do {
            try await pointer.waitForPointer(sessionID: sessionID)
        } catch let held as BrowserReplPointerOwner.Held {
            throw Self.pointerHeldError(held)
        }
    }

    /// Runs a whole drag as one press of `sessionID`: it waits for another
    /// session's press to end, and no other session's mouse input reaches
    /// the page until the drag ends.
    func performPointerGesture<T>(sessionID: String, _ gesture: () async throws -> T) async throws -> T {
        do {
            return try await pointer.performGesture(sessionID: sessionID, gesture)
        } catch let held as BrowserReplPointerOwner.Held {
            throw Self.pointerHeldError(held)
        }
    }

    private static func pointerHeldError(_ held: BrowserReplPointerOwner.Held) -> BrowserReplDriverError {
        WebKitBrowserReplDriver.error(
            "timeout",
            "Session \(held.owner) holds the mouse on this tab: it pressed a button and has not released it within \(held.timeout); call page.mouse.up() in that session or reset it"
        )
    }

    func pointerPressed(sessionID: String) { pointer.pressed(sessionID: sessionID) }

    func pointerReleased(sessionID: String) { pointer.released(sessionID: sessionID) }
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

    private var authenticationFailure: String?

    /// Why the last navigation was refused by an HTTP auth challenge, once.
    func takeAuthenticationFailure() -> String? {
        defer { authenticationFailure = nil }
        return authenticationFailure
    }

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
        // A user's tab keeps its sign-in prompt.
        guard appliesSessionPolicies else { return nil }
        // No credential, or a wrong one: the navigation fails and names the
        // challenge (see `takeAuthenticationFailure`). Cancelling, unlike
        // loading the page without credentials, leaves the protection space
        // free to accept credentials given in a later URL.
        authenticationFailure = "HTTP authentication (\(space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ? "Digest" : "Basic")) required by \(space.host):\(space.port)\(space.realm.map { " realm \"\($0)\"" } ?? "")\(challenge.previousFailureCount > 0 ? "; the credentials were rejected" : ""); give them in the URL: http://user:password@host/..."
        return (.cancelAuthenticationChallenge, nil)
    }
    /// Finished downloads by id.
    private(set) var downloadPaths: [String: String] = [:]
    /// HTTP status of the latest main-document response.
    private(set) var mainDocumentStatus: Int?
    /// Increments on every request start, so `networkidle` can tell a quiet
    /// period from one where requests started and finished.
    private(set) var requestGeneration = 0
    /// The page agent's document-start user script in the tab's controller.
    private let agentUserScript = BrowserReplAgentUserScript()

    init(panel: BrowserPanel) {
        panelID = panel.id
        self.panel = panel
    }

    var isAttached: Bool { !sinks.isEmpty }
    var sessionIDs: [String] { Array(sinks.keys).sorted() }
    var targetID: String { panelID.uuidString }

    /// Which events the sessions take over in this tab.
    private var ownership = BrowserReplTabOwnership()

    /// Marks this tab as created by `sessionID` (`tabs.open`, or a popup of
    /// a tab it created): the session's behaviors apply to it.
    func markCreated(by sessionID: String) {
        ownership.markCreated(by: sessionID)
        applyContextToWebView()
    }

    /// `tab.handleEvents`: the events `sessionID` has a handler for here.
    func setHandledEvents(_ events: Set<BrowserReplTabEvent>, sessionID: String) {
        ownership.setHandledEvents(events, for: sessionID)
    }

    /// Runs `body`, a session's input or navigation on this tab: a dialog or
    /// file chooser the page opens meanwhile goes to that session, also in
    /// a user's tab (``BrowserReplTabOwnership/beginInput(sessionID:)``).
    func withInput<T>(sessionID: String, _ body: () async throws -> T) async rethrows -> T {
        ownership.beginInput(sessionID: sessionID)
        defer { ownership.endInput(sessionID: sessionID) }
        return try await body()
    }

    /// The attached session whose input the page is handling now, if any.
    var inputSessionID: String? {
        guard let sessionID = ownership.inputSessionID, sinks[sessionID] != nil else { return nil }
        return sessionID
    }

    /// Whether `event` goes to a session instead of cmux's UI.
    func routesToSessions(_ event: BrowserReplTabEvent) -> Bool {
        recipient(for: event) != nil
    }

    /// The one attached session `event` goes to (``BrowserReplTabOwnership/recipient(for:)``).
    /// Only it receives the event and may answer it.
    private func recipient(for event: BrowserReplTabEvent) -> String? {
        guard isAttached, let sessionID = ownership.recipient(for: event), sinks[sessionID] != nil else { return nil }
        return sessionID
    }

    /// Whether a session created this tab, so permission requests answer
    /// from `session.configure` and the insecure-HTTP prompt is skipped.
    var appliesSessionPolicies: Bool {
        isAttached && ownership.isSessionOwned
    }

    /// The attached session that created this tab, whose domain policy may
    /// cancel its navigations (BrowserReplNavigationGuard).
    var creatorSessionID: String? {
        isAttached && ownership.isSessionOwned ? ownership.creatorSessionID : nil
    }

    func addSink(sessionID: String, sink: @escaping BrowserReplTabEventSink) {
        let wasAttached = isAttached
        sinks[sessionID] = sink
        ownership.attach(sessionID: sessionID)
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
        pointerReleased(sessionID: sessionID)
        // Dialogs and choosers routed to the leaving session are answered as
        // unhandled ones are; no other session may answer them.
        for respond in dialogs.removeAll(ownedBy: sessionID) { respond(false, nil) }
        for chooser in fileChoosers.removeAll(ownedBy: sessionID) { chooser.respond(nil) }
        sinks.removeValue(forKey: sessionID)
        ownership.detach(sessionID: sessionID)
        if sinks.isEmpty {
            detachAll()
        } else {
            // The tab carries its creator's options while the creator stays
            // attached; once the creator leaves it is the user's again.
            applyContextToWebView()
        }
    }

    // MARK: - Browser-context options

    /// The `session.configure` options and domain-policy rule list the tab
    /// carries: those of the attached session that created it. A user's tab
    /// (one the user opened, a kept one, or one whose creator left) carries
    /// none, also while sessions drive it: it keeps its own user agent,
    /// headers and content, and the domain policy only refuses the
    /// sessions' reads and input there.
    var contextOptions: BrowserReplContextOptions {
        guard appliesSessionPolicies, let creator = ownership.creatorSessionID,
              let options = BrowserReplTabAttachments.shared.context(forSession: creator) else {
            return BrowserReplContextOptions()
        }
        return options
    }

    /// The domain-policy rule list installed in the current web view.
    private var installedRuleList: WKContentRuleList?
    private weak var ruleListWebView: WKWebView?

    /// Whether the creating session granted `permission` (`camera`,
    /// `microphone`, `geolocation`, `notifications`). Grants apply only to
    /// tabs the session created; a user's tab keeps cmux's own answer.
    func grants(_ permission: String) -> Bool {
        contextOptions.permissions.contains(permission)
    }

    /// Puts ``contextOptions`` (user agent, headers, domain rule list) on
    /// the panel's current web view (again after WebKit replaced it), and
    /// the page clipboard guard on the web view of a tab a session created.
    func applyContextToWebView() {
        guard let webView = panel?.webView else { return }
        if appliesSessionPolicies {
            guardPageClipboard(webView)
        }
        if webView.automationUserAgentOverride != contextOptions.userAgent {
            webView.automationUserAgentOverride = contextOptions.userAgent
        }
        webView.automationExtraHTTPHeaders = contextOptions.extraHTTPHeaders
        let wanted = contextOptions.ruleList
        if let installed = installedRuleList, let owner = ruleListWebView,
           installed !== wanted || owner !== webView {
            owner.configuration.userContentController.remove(installed)
            installedRuleList = nil
            ruleListWebView = nil
        }
        if let wanted, installedRuleList == nil {
            webView.configuration.userContentController.add(wanted)
            installedRuleList = wanted
            ruleListWebView = webView
        }
    }

    /// Keeps the page's scripts from writing the system clipboard in a tab a
    /// session created (``BrowserReplPageClipboard``): WebKit's asynchronous
    /// Clipboard API is off and `page-clipboard.js` sends the page's Clipboard
    /// API and `execCommand("copy" | "cut")` writes to the tab's clipboard
    /// (``clipboardItems``). The guard stays on the web view for its life,
    /// also after the session leaves: a page loaded while the session drove
    /// the tab never gets the system clipboard. Writes after that fail.
    ///
    /// The guard fails closed: `tabs.open` refuses to open a tab when WebKit
    /// cannot turn its Clipboard API off (``BrowserReplPageClipboard/isSupported``),
    /// and a popup or a replaced web view of such a tab runs in the same
    /// WebKit. Should the guard still not install, the web view's page is
    /// stopped and replaced by an empty document with no script, so no page
    /// there holds the agent's gestures with the system clipboard in reach.
    private func guardPageClipboard(_ webView: WKWebView) {
        let installed = BrowserReplTabAttachments.shared.pageClipboard?.install(on: webView) { webView, items in
            guard let attachment = BrowserReplTabAttachments.shared.attachment(showing: webView) else { return false }
            attachment.clipboardItems = items
            return true
        } ?? false
        guard !installed else { return }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Releases held dialogs and choosers and removes page instrumentation.
    func detachAll() {
        sinks.removeAll()
        ownership = BrowserReplTabOwnership()
        // Playwright dismisses dialogs nobody handles; do the same so a page
        // is never left blocked on a dialog after its session goes away.
        for respond in dialogs.removeAll() { respond(false, nil) }
        for chooser in fileChoosers.removeAll() { chooser.respond(nil) }
        releaseHeldInput()
        uninstrument()
        agentUserScript.release()
        applyContextToWebView()
        releaseRenderHost()
        if let webView = occlusionDisabledWebView {
            Self.setOcclusionDetection(true, on: webView)
            occlusionDisabledWebView = nil
        }
        panel?.reevaluateHiddenWebViewDiscardScheduling(reason: "browser.repl.detach")
        let waiters = networkIdleWaiters
        networkIdleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Hands the tab back with no automated input in progress: keys and
    /// buttons the sessions left pressed get their key-up and mouse-up (or
    /// the drag they started ends), and automated right clicks whose menu
    /// never opened stop suppressing the user's next context menu.
    private func releaseHeldInput() {
        let keys = heldKeys.releaseAll()
        let buttons = mouseState.pressedButtons
        mouseState.reset()
        let dragState = drag
        drag = nil
        guard let webView = panel?.webView as? CmuxWebView else { return }
        webView.cancelPendingAutomationContextMenus()
        webView.automationDragCapture = nil
        if webView.window != nil {
            for stroke in keys {
                _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: false)
            }
        }
        webView.releaseBrowserReplModifiers()
        guard let window = webView.window else { return }
        let location = BrowserReplNativeInput.windowPoint(webView: webView, cssPoint: mousePosition)
        for button in buttons.reversed() {
            if button == .left, let drop = dragState?.drop {
                drop.draggingLocation = location
                webView.draggingExited(drop)
                webView.endAutomationDrag(at: location, operation: [])
                continue
            }
            let type: NSEvent.EventType = switch button {
            case .left: .leftMouseUp
            case .right: .rightMouseUp
            case .middle: .otherMouseUp
            }
            if let event = BrowserReplNativeInput.mouseEvent(
                type: type,
                button: button,
                webView: webView,
                window: window,
                cssPoint: mousePosition,
                clickCount: 1,
                modifierFlags: []
            ) {
                webView.deliverAutomationMouseEvent(event)
            }
        }
    }

    /// Sends an event to every attached session.
    func emit(_ name: String, _ payload: [String: Any]) {
        var body = payload
        body["targetId"] = targetID
        for sink in sinks.values { sink(name, body) }
    }

    /// Sends a routed event (dialog, file chooser, download) to the one
    /// session it was routed to.
    private func emit(_ name: String, _ payload: [String: Any], to sessionID: String) {
        var body = payload
        body["targetId"] = targetID
        sinks[sessionID]?(name, body)
    }

    private func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }

    // MARK: - Instrumentation

    /// Installs network and console reporting on the panel's current web
    /// view. Called on attach and again when the panel replaces its web view.
    func instrumentCurrentWebView() {
        if isAttached { applyContextToWebView() }
        guard let webView = panel?.webView, webView !== instrumentedWebView, isAttached else { return }
        uninstrument()
        // A web view after the first is a replacement (a restore of a page
        // cmux unloaded, a crash recovery): its frames have new ids.
        let isReplacement = hasInstrumentedWebView
        hasInstrumentedWebView = true
        instrumentedWebView = webView
        if isReplacement { emit("tab.replaced", [:]) }
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
        guard let webView = panel?.webView else { return }
        agentUserScript.install(
            source: source,
            presenceHandlerName: BrowserReplAgentPresenceHandler.name,
            world: BrowserReplAgentWorld.world,
            in: webView.configuration.userContentController
        )
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

    /// Routes a JavaScript dialog to the one session that takes dialogs in
    /// this tab; only that session sees and answers it.
    /// - Returns: `false` when no session takes dialogs in this tab; the
    ///   caller shows its native UI.
    func handleDialog(
        type: String,
        message: String,
        defaultValue: String?,
        respond: @escaping (Bool, String?) -> Void
    ) -> Bool {
        guard let owner = recipient(for: .dialog) else { return false }
        let id = makeID("d")
        if let command = clipboardCommandsInFlight.last {
            // Held, the dialog would keep WebKit's Copy, Cut or Paste open.
            // Answer it as a dialog nobody handles is answered, and report it.
            respond(false, nil)
            emit("dialog.opened", [
                "dialogId": id,
                "type": type,
                "message": message,
                "defaultValue": defaultValue ?? "",
                "dismissedDuring": command,
            ], to: owner)
            return true
        }
        dialogs.add(id: id, owner: owner, respond: respond)
        emit("dialog.opened", [
            "dialogId": id,
            "type": type,
            "message": message,
            "defaultValue": defaultValue ?? "",
        ], to: owner)
        return true
    }

    /// Copy, Cut and Paste commands (`copy`, `cut`, `paste`) WebKit is running
    /// in this tab, until WebKit reports each done. A JavaScript dialog that
    /// opens meanwhile is dismissed at once and reported with
    /// `dismissedDuring`, never held.
    var clipboardCommandsInFlight: [String] = []

    func clipboardCommandFinished(_ command: String) {
        if let index = clipboardCommandsInFlight.firstIndex(of: command) {
            clipboardCommandsInFlight.remove(at: index)
        }
    }

    /// Whether a JavaScript dialog is waiting for `dialog.respond`; page
    /// script is blocked until it is answered.
    var hasPendingDialog: Bool { !dialogs.isEmpty }

    /// The last `tab.info` answered from the page, reused while a dialog blocks it.
    var lastInfo: [String: Any]?

    /// Answers dialog `id` when `sessionID` is the session it was routed to.
    func respondToDialog(id: String, sessionID: String, accept: Bool, promptText: String?) -> Bool {
        guard let respond = dialogs.take(id: id, sessionID: sessionID) else { return false }
        respond(accept, promptText)
        return true
    }

    // MARK: - File choosers

    /// Routes a file input's open panel to the one session that takes file
    /// choosers in this tab; only that session sees and answers it.
    func handleOpenPanel(
        allowsMultiple: Bool,
        frame: WKFrameInfo,
        respond: @escaping ([URL]?) -> Void
    ) -> Bool {
        guard let owner = recipient(for: .fileChooser) else { return false }
        let id = makeID("c")
        fileChoosers.add(id: id, owner: owner, respond: (respond, frame))
        let frameID = frame.isMainFrame ? nil : BrowserReplFrameTree.frameID(of: frame)
        Task { @MainActor [weak self] in
            let element = await self?.chooserElementHandle(in: frame)
            self?.emit("filechooser.opened", [
                "chooserId": id,
                "frameId": frameID ?? NSNull(),
                "element": element ?? NSNull(),
                "multiple": allowsMultiple,
            ], to: owner)
        }
        return true
    }

    /// Answers file chooser `id` when `sessionID` is the session it was routed to.
    func respondToFileChooser(id: String, sessionID: String, files: [URL]?) -> Bool {
        guard let chooser = fileChoosers.take(id: id, sessionID: sessionID) else { return false }
        chooser.respond(files)
        return true
    }

    /// The frame file chooser `id` opened from, when `sessionID` is the
    /// session it was routed to.
    func fileChooserFrame(id: String, sessionID: String) -> WKFrameInfo? {
        fileChoosers.value(id: id, sessionID: sessionID)?.frame
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

    /// - Parameter forInputSession: The session whose input the opener, a
    ///   user's tab, was handling: the popup goes to that session only and
    ///   stays the user's (`BrowserReplPopupRoute.inputSession`).
    func adoptPopup(request: URLRequest, configuration: WKWebViewConfiguration, forInputSession: String? = nil) -> PopupAdoption? {
        guard isAttached, let panel,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              let pane = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        let url = request.url ?? URL(string: "about:blank")!
        // WebKit's popup configuration shares the opener's user content
        // controller; the new panel installs its own scripts and message
        // handlers, so it gets a controller of its own (a shared one would
        // register the same handler names twice). The opener link does not
        // depend on the controller.
        configuration.userContentController = WKUserContentController()
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
        announcePopup(created, url: url, forInputSession: forInputSession)
        return .opened(created.webView === webView ? webView : nil)
    }

    private func announcePopup(_ created: BrowserPanel, url: URL, forInputSession: String? = nil) {
        // A popup a user's tab opened for a session's input goes to that
        // session only, and stays the user's: no creator, never closed with
        // the session (`userOwned`).
        let recipients = forInputSession.map { id in sinks.filter { $0.key == id } } ?? sinks
        var child: BrowserReplTabAttachment?
        for (sessionID, sink) in recipients {
            child = BrowserReplTabAttachments.shared.attach(panel: created, sessionID: sessionID, sink: sink)
        }
        child?.openerTargetID = targetID
        // A popup of a tab a session created is that session's too.
        if forInputSession == nil, ownership.isSessionOwned, let creator = ownership.creatorSessionID {
            child?.markCreated(by: creator)
        }
        var payload: [String: Any] = [
            "targetId": created.id.uuidString,
            "openerTargetId": targetID,
            "url": url.absoluteString,
        ]
        if forInputSession != nil { payload["userOwned"] = true }
        for sink in recipients.values {
            sink("tab.created", payload)
        }
    }

    func handlePopup(request: URLRequest, forInputSession: String? = nil) -> Bool {
        guard isAttached, let panel, let url = request.url,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              let pane = workspace.paneId(forPanelId: panel.id) else {
            return false
        }
        // The new tab stays in the opener's profile and data store, as a
        // user's Cmd-click does (`BrowserPanel` new-tab requests): a session
        // tab on a private `session.configure({ proxy })` store keeps it.
        guard let created = workspace.newBrowserSurface(
            inPane: pane,
            url: url,
            focus: false,
            preferredProfileID: panel.profileID,
            creationPolicy: .automationPreload,
            websiteDataStore: panel.explicitEphemeralWebsiteDataStoreForSibling
        ) else {
            return false
        }
        announcePopup(created, url: url, forInputSession: forInputSession)
        return true
    }

    // MARK: - Downloads

    /// Downloads reported to a session, by id, with that session.
    private var sessionDownloads: [String: String] = [:]

    /// Whether download `id` went to a session. Those stay in cmux's
    /// temporary download directory, so `download.path()` can read them;
    /// every other download takes the user's normal path.
    func keepsDownloadInTemporaryDirectory(id: String) -> Bool {
        sessionDownloads[id] != nil
    }

    /// Reports a download to the one session that takes downloads in this
    /// tab; the decision, and that session, hold for the download's life.
    func downloadDidStart(id: String, url: URL?, suggestedFilename: String) {
        guard let owner = recipient(for: .download) else { return }
        sessionDownloads[id] = owner
        emit("download.started", [
            "downloadId": id,
            "url": url?.absoluteString ?? "",
            "suggestedFilename": suggestedFilename,
        ], to: owner)
    }

    func downloadDidFinish(id: String, path: String?, error: String?) {
        guard let owner = sessionDownloads.removeValue(forKey: id) else { return }
        if let path { downloadPaths[id] = path }
        var payload: [String: Any] = ["downloadId": id]
        if let path { payload["path"] = path }
        if let error { payload["error"] = error }
        emit("download.finished", payload, to: owner)
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

    @MainActor static let world = WKContentWorld.browserReplWorld(seeingClosedShadowRoots: name)
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

/// Playwright browser-context options a REPL session applies to the tabs it
/// drives (`session.configure`).
struct BrowserReplContextOptions {
    var userAgent: String?
    /// Added to main-frame GET navigations. WebKit has no request
    /// interception, so subresource requests do not carry them.
    var extraHTTPHeaders: [String: String] = [:]
    /// Granted permissions; every other request is denied at once.
    var permissions: Set<String> = []
    /// Compiled `session.allowedDomains` / `prohibitedDomains` rules that
    /// block subresource loads.
    var ruleList: WKContentRuleList?
}

/// Data stores created for `session.configure({ proxy })`. Their proxy is
/// fixed; panel proxy mirroring leaves them alone.
@MainActor
enum BrowserReplProxyStores {
    private static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()

    static func register(_ store: WKWebsiteDataStore) {
        stores.add(store)
    }

    static func owns(_ store: WKWebsiteDataStore) -> Bool {
        stores.contains(store)
    }
}
