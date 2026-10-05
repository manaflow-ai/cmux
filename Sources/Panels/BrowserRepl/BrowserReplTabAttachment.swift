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
    /// Sessions read it off the main thread (their fetch responses, files
    /// and output), so it is not main-actor state.
    nonisolated static let typedSecrets = BrowserReplTypedSecrets()

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
        Self.typedSecrets.sessionLeft(sessionID)
        for (panelID, attachment) in attachments {
            attachment.removeSink(sessionID: sessionID)
            if !attachment.isAttached {
                attachments.removeValue(forKey: panelID)
            }
        }
    }

    /// Detaches everything from a panel that is closing.
    func panelDidClose(_ panelID: UUID) {
        Self.typedSecrets.tabClosed(panelID.uuidString)
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
    /// to; only that session answers one. Each dialog keeps the document of
    /// the frame that opened it, judged again when the session answers.
    private var dialogs = BrowserReplRoutedRequests<(respond: (Bool, String?) -> Void, document: BrowserReplFrameDocument)>()
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
    /// Keys held by automation, by the session that pressed each; a session
    /// releases its own when it leaves (``takeHeldInput(of:)``).
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

    /// Whether `sessionID`'s press is in progress on this tab.
    func holdsPointer(sessionID: String) -> Bool { pointer.owner == sessionID }

    func pointerReleased(sessionID: String) { pointer.released(sessionID: sessionID) }
    /// The drag in progress, between a left press and its release.
    var drag: DragState?
    /// Last automated mouse position in CSS pixels.
    var mousePosition = CGPoint.zero
    /// Per-tab virtual clipboard (`clipboard.read` / `clipboard.write`,
    /// Meta+C, Meta+X and Meta+V, and the page's own writes in a tab a
    /// session created): the live creator's alone (``BrowserReplTabClipboard``).
    /// Its owner follows ``creatorSessionID`` (``syncClipboardOwner()``).
    var clipboard = BrowserReplTabClipboard<[String: Any]>()

    /// Hands the clipboard to the tab's live creator, or takes it away from
    /// a creator that left: it empties, and nothing begun before lands.
    private func syncClipboardOwner() {
        clipboard.setOwner(creatorSessionID)
    }
    /// Target id of the tab that opened this one, for popups.
    var openerTargetID: String?
    /// Credentials from `user:password@` in URLs a session navigated to, by
    /// session and `host:port`. HTTP auth challenges in a driven tab answer
    /// from the acting session's or the creator's own, instead of showing a
    /// prompt nobody can answer (``BrowserReplHTTPCredentials``).
    private var httpCredentials = BrowserReplHTTPCredentials()

    private var authenticationFailure: String?

    /// Why the last navigation was refused by an HTTP auth challenge, once.
    func takeAuthenticationFailure() -> String? {
        defer { authenticationFailure = nil }
        return authenticationFailure
    }

    /// Remembers the credentials in `url`, which `sessionID` navigates to,
    /// as that session's alone.
    func rememberCredentials(in url: URL, sessionID: String) {
        httpCredentials.remember(url, sessionID: sessionID)
    }

    /// The answer to an HTTP authentication challenge in a driven tab: the
    /// acting session's (or, in a tab a session created, the creator's)
    /// URL credentials once, then the unauthenticated response (a 401 page
    /// the session sees) instead of a prompt. Another session's credentials
    /// never answer it.
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
        if challenge.previousFailureCount == 0,
           let credential = httpCredentials.credential(
               host: space.host,
               port: space.port,
               actingSession: inputSessionID,
               creator: creatorSessionID
           ) {
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
        syncClipboardOwner()
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

    /// Like ``withInput(sessionID:_:)``, but the window closes after `limit`
    /// even while `body` still runs (``BrowserReplBoundedWindow``): a page
    /// script's own dialogs come soon after it starts, and a long one must
    /// not take the user's dialogs and popups in this tab.
    func withInput<T>(
        sessionID: String,
        atMost limit: Duration,
        sleeper: any BrowserReplSleeping,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await BrowserReplBoundedWindow(limit: limit, sleeper: sleeper).run(
            begin: { ownership.beginInput(sessionID: sessionID) },
            end: { [weak self] in self?.ownership.endInput(sessionID: sessionID) },
            body
        )
    }

    /// Whether a window this tab's page opens through the browser's own path
    /// (not caused by a session's input) opens as a background tab instead
    /// of a key popup window: sessions drive the tab and the user is not
    /// working in it (it is not shown, focused, in the key window of the
    /// active app). A page that opens one after an await in an agent's
    /// click handler (`await fetch(); window.open()`) is past the input
    /// window, and must still not put a key window over the user's work.
    var opensPopupsInBackground: Bool {
        guard isAttached, let panel else { return false }
        guard panel.isWebViewVisibleInPane, NSApp.isActive,
              let window = panel.webView.window, !(window is BrowserOffscreenRenderPanel), window.isKeyWindow,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              workspace.focusedPanelId == panel.id else {
            return true
        }
        return false
    }

    /// The attached session whose input the page is handling now, if
    /// exactly one session's input is in flight
    /// (``BrowserReplTabOwnership/inputSessionID``).
    var inputSessionID: String? {
        guard let sessionID = ownership.inputSessionID, sinks[sessionID] != nil else { return nil }
        return sessionID
    }

    /// Whether `event` goes to a session instead of cmux's UI.
    func routesToSessions(_ event: BrowserReplTabEvent) -> Bool {
        recipient(for: event) != nil
    }

    /// The one attached session `event` goes to (``BrowserReplTabOwnership/route(for:)``).
    /// Only it receives the event and may answer it.
    private func recipient(for event: BrowserReplTabEvent) -> String? {
        if case .session(let sessionID) = route(for: event) { return sessionID }
        return nil
    }

    /// Where `event` goes; ``BrowserReplEventRoute/user`` when the tab has
    /// no attached session or the chosen one has no sink.
    private func route(for event: BrowserReplTabEvent) -> BrowserReplEventRoute {
        guard isAttached else { return .user }
        return deliverable(ownership.route(for: event))
    }

    /// Where a dialog or file chooser `frame` opened goes: never to a
    /// session whose domain policy blocks that frame's document
    /// (``BrowserReplTabOwnership/route(for:from:policy:)``).
    private func route(for event: BrowserReplTabEvent, from frame: WKFrameInfo) -> BrowserReplEventRoute {
        guard isAttached else { return .user }
        return deliverable(ownership.route(for: event, from: BrowserReplFrameDocument(info: frame)) {
            BrowserReplPolicyBoard.shared.policy(for: $0)
        })
    }

    private func deliverable(_ route: BrowserReplEventRoute) -> BrowserReplEventRoute {
        if case .session(let sessionID) = route, sinks[sessionID] == nil { return .user }
        return route
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

    /// The live session that created this tab when it is not `sessionID`,
    /// which then may not drive it (``BrowserReplTabOwnership/ownerRefusing(_:)``).
    func ownerRefusing(_ sessionID: String) -> String? {
        guard isAttached, let owner = ownership.ownerRefusing(sessionID), sinks[owner] != nil else { return nil }
        return owner
    }

    func addSink(sessionID: String, sink: @escaping BrowserReplTabEventSink) {
        let wasAttached = isAttached
        sinks[sessionID] = sink
        ownership.attach(sessionID: sessionID)
        syncClipboardOwner()
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
        // Input the session still holds was released through the session's
        // guards when it ended (the driver's `releaseHeldInput`); what is
        // left (a release the guards refused) is dropped without a native
        // event, so no other session inherits it and no unguarded trusted
        // event reaches the page.
        dropHeldInput(of: sessionID)
        pointerReleased(sessionID: sessionID)
        // Dialogs and choosers routed to the leaving session are answered as
        // unhandled ones are; no other session may answer them.
        for dialog in dialogs.removeAll(ownedBy: sessionID) { dialog.respond(false, nil) }
        for chooser in fileChoosers.removeAll(ownedBy: sessionID) { chooser.respond(nil) }
        sinks.removeValue(forKey: sessionID)
        httpCredentials.sessionLeft(sessionID)
        // What the creating session copied or wrote is its own; a session
        // that drives the kept tab later never reads it, and a Copy still
        // running for it never lands.
        ownership.detach(sessionID: sessionID)
        syncClipboardOwner()
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

    /// Whether the creating session granted `request` (`camera`,
    /// `microphone`, `geolocation`, `notifications`) to the origin and frame
    /// that ask: only those its current domain policy allows
    /// (``BrowserReplPermissionRequest/isGranted(by:policy:)``). Grants apply
    /// only to tabs the session created; a user's tab keeps cmux's own answer.
    func grants(_ request: BrowserReplPermissionRequest) -> Bool {
        guard let creator = creatorSessionID else { return false }
        return request.isGranted(by: contextOptions.permissions, policy: BrowserReplPolicyBoard.shared.policy(for: creator))
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
    /// (``clipboard``). The guard stays on the web view for its life,
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
        let installed = BrowserReplTabAttachments.shared.pageClipboard?.install(
            on: webView,
            refusing: { webView, frame in
                // A frame the creating session's policy blocks can still run
                // here (it loaded before the policy tightened); what it
                // writes must not reach the agent through clipboard.read.
                guard let creator = BrowserReplTabAttachments.shared.attachment(showing: webView)?.creatorSessionID,
                      let policy = BrowserReplPolicyBoard.shared.policy(for: creator) else { return nil }
                return policy.blockReason(document: BrowserReplFrameDocument(info: frame))
            },
            onWrite: { webView, items in
                // Only while the creating session holds the tab: a kept tab's
                // page writes nowhere once its creator left.
                guard let attachment = BrowserReplTabAttachments.shared.attachment(showing: webView) else { return false }
                return attachment.clipboard.writeFromPage(items)
            }
        ) ?? false
        guard !installed else { return }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Releases held dialogs and choosers and removes page instrumentation.
    func detachAll() {
        sinks.removeAll()
        ownership = BrowserReplTabOwnership()
        syncClipboardOwner()
        httpCredentials = BrowserReplHTTPCredentials()
        // Playwright dismisses dialogs nobody handles; do the same so a page
        // is never left blocked on a dialog after its session goes away.
        for dialog in dialogs.removeAll() { dialog.respond(false, nil) }
        for chooser in fileChoosers.removeAll() { chooser.respond(nil) }
        resetHeldInput()
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

    /// Keys and buttons one session holds down in this tab.
    struct HeldInput {
        /// The session that holds it.
        var sessionID = ""
        var keys: [BrowserReplKeyStroke] = []
        var buttons: [BrowserReplMouseButton] = []
        var drag: DragState?

        var isEmpty: Bool { keys.isEmpty && buttons.isEmpty && drag == nil }
    }

    /// What `sessionID` holds down here, forgotten: its keys (last pressed
    /// first), and its mouse buttons and drag when its press is the one in
    /// progress (``BrowserReplPointerOwner``: only one session presses at a
    /// time). Another session's keys and press stay.
    func takeHeldInput(of sessionID: String) -> HeldInput {
        var held = HeldInput(sessionID: sessionID, keys: heldKeys.releaseAll(heldBy: sessionID))
        if pointer.owner == sessionID {
            held.buttons = mouseState.pressedButtons
            held.drag = drag
            mouseState.reset()
            drag = nil
            pointerReleased(sessionID: sessionID)
        }
        return held
    }

    /// Delivers the key-up of each held key and the button-up of each held
    /// button at the last mouse position (or ends the drag), as trusted
    /// events. Only the driver calls this, for a session that ends, inside
    /// that session's input guards: the clipboard quarantine and the frame
    /// gate (`WebKitBrowserReplDriver.releaseHeldInput`).
    func deliverRelease(_ held: HeldInput) {
        guard !held.isEmpty, let webView = panel?.webView as? CmuxWebView else { return }
        if held.drag != nil { webView.automationDragCapture = nil }
        if webView.window != nil {
            for stroke in held.keys {
                _ = webView.replayBrowserReplKeyStroke(stroke, keyDown: false, heldBy: held.sessionID)
            }
        }
        guard let window = webView.window else { return }
        let location = BrowserReplNativeInput.windowPoint(webView: webView, cssPoint: mousePosition)
        for button in held.buttons.reversed() {
            if button == .left, let drop = held.drag?.drop {
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

    /// Forgets what `sessionID` still holds without sending the page any
    /// event (its release was refused by its guards, or never ran): its
    /// modifier keys stop applying to later input, a drag it started ends
    /// without a drop, and no other session inherits its keys or press.
    private func dropHeldInput(of sessionID: String) {
        forgetReleased(takeHeldInput(of: sessionID))
    }

    /// Forgets `held` (from ``takeHeldInput(of:)``) without sending the page
    /// any event: a release its session's guards refused.
    func forgetReleased(_ held: HeldInput) {
        guard !held.isEmpty, let webView = panel?.webView as? CmuxWebView else { return }
        for stroke in held.keys {
            webView.forgetBrowserReplModifier(stroke, heldBy: held.sessionID)
        }
        endDragSilently(held.drag, in: webView)
    }

    /// Hands the tab back with no automated input in progress, without
    /// sending the page an unguarded trusted event: every session's held
    /// keys and buttons are forgotten (each session released its own
    /// through its guards when it ended), a drag in progress ends without a
    /// drop, and automated right clicks whose menu never opened stop
    /// suppressing the user's next context menu.
    private func resetHeldInput() {
        _ = heldKeys.releaseAll()
        mouseState.reset()
        let dragState = drag
        drag = nil
        guard let webView = panel?.webView as? CmuxWebView else { return }
        webView.cancelPendingAutomationContextMenus()
        endDragSilently(dragState, in: webView)
        webView.releaseBrowserReplModifiers()
    }

    /// Ends the automated drag session `dragState` started, if any: WebKit's
    /// drag source is told it ended with no operation (the page gets
    /// `dragend`, which grants no user gesture). No mouse, key or drop
    /// event reaches the page.
    private func endDragSilently(_ dragState: DragState?, in webView: CmuxWebView) {
        guard let dragState else { return }
        webView.automationDragCapture = nil
        if dragState.drop != nil, webView.window != nil {
            let location = BrowserReplNativeInput.windowPoint(webView: webView, cssPoint: mousePosition)
            webView.endAutomationDrag(at: location, operation: [])
        }
    }

    /// Sends an event to every attached session.
    func emit(_ name: String, _ payload: [String: Any]) {
        var body = payload
        body["targetId"] = targetID
        for sink in sinks.values { sink(name, body) }
    }

    /// Sends a console message or page error from `document` only to the
    /// sessions whose domain policy allows that document
    /// (``BrowserReplPageTelemetry``).
    private func emitTelemetry(_ name: String, _ payload: [String: Any], from document: BrowserReplFrameDocument) {
        var body = payload
        body["targetId"] = targetID
        let recipients = BrowserReplPageTelemetry().recipients(of: document, among: Array(sinks.keys)) {
            BrowserReplPolicyBoard.shared.policy(for: $0)
        }
        for sessionID in recipients { sinks[sessionID]?(name, body) }
    }

    /// Sends a network event only to the sessions it belongs to
    /// (``BrowserReplTabOwnership/networkRecipients(event:requestID:)``),
    /// with its credentials (headers, and credential values in URLs) only
    /// for the tab's creator.
    private func emitNetwork(_ name: String, _ payload: [String: Any]) {
        let requestID = payload["requestId"] as? String ?? ""
        for recipient in ownership.networkRecipients(event: name, requestID: requestID) {
            guard let sink = sinks[recipient.sessionID] else { continue }
            var body = recipient.seesCredentials ? payload : payload.redactingBrowserReplCredentials()
            body["targetId"] = targetID
            sink(name, body)
        }
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
            self.emitNetwork(event, payload)
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
        let handler = BrowserReplConsoleMessageHandler { [weak self] event, payload, document in
            self?.emitTelemetry(event, payload, from: document)
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
        frame: WKFrameInfo,
        respond: @escaping (Bool, String?) -> Void
    ) -> Bool {
        let owner: String
        switch route(for: .dialog, from: frame) {
        case .user:
            return false
        case .refused:
            // Inputs of two sessions were in flight: the dialog may be
            // either's, so neither answers it, and the user is not asked.
            respond(false, nil)
            return true
        case .session(let sessionID):
            owner = sessionID
        }
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
        dialogs.add(id: id, owner: owner, respond: (respond, BrowserReplFrameDocument(info: frame)))
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
    /// - Returns: `false` when the dialog is gone or another session's.
    /// - Throws: `blocked` when `sessionID`'s domain policy now blocks the
    ///   document that opened the dialog (it changed since the dialog
    ///   opened): the dialog is dismissed, as an unhandled one is, and the
    ///   session's answer never reaches that page.
    func respondToDialog(id: String, sessionID: String, accept: Bool, promptText: String?) throws -> Bool {
        guard let dialog = dialogs.take(id: id, sessionID: sessionID) else { return false }
        if let reason = BrowserReplPolicyBoard.shared.policy(for: sessionID)?.blockReason(document: dialog.document) {
            dialog.respond(false, nil)
            throw WebKitBrowserReplDriver.error("blocked", "Dialog \(id) came from a frame showing \(dialog.document.origin ?? dialog.document.place), which the domain policy blocks: \(reason); it was dismissed")
        }
        dialog.respond(accept, promptText)
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
        let owner: String
        switch route(for: .fileChooser, from: frame) {
        case .user:
            return false
        case .refused:
            // As for a dialog: no session may pick files for another's input.
            respond(nil)
            return true
        case .session(let sessionID):
            owner = sessionID
        }
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
        let value = try? await webView.browserReplCallAsyncJavaScript(
            source,
            arguments: [:],
            in: frame,
            contentWorld: BrowserReplAgentWorld.world,
            userGesture: false
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

    /// - Parameters:
    ///   - forInputSession: The session whose input the opener, a user's
    ///     tab, was handling: the popup goes to that session only and stays
    ///     the user's (`BrowserReplPopupRoute.inputSession`).
    ///   - announce: `false` opens a user's popup as a background tab and
    ///     tells no session (``opensPopupsInBackground``). It never applies
    ///     to a tab a session created, whose popups are always handed to
    ///     that session before they load (``handsPopupsOverFirst(forInputSession:)``).
    func adoptPopup(request: URLRequest, configuration: WKWebViewConfiguration, forInputSession: String? = nil, announce: Bool = true) -> PopupAdoption? {
        let handsOver = handsPopupsOverFirst(forInputSession: forInputSession)
        let announce = announce || handsOver
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
        guard created.webView === webView else {
            // The panel did not take WebKit's web view, so it loads the URL
            // itself, and it started before the session's content rules and
            // page clipboard guard are on it. Close it on this main-actor
            // turn, before WebKit decides that navigation, and let the
            // caller open the popup blank first (`handlePopup`).
            if handsOver {
                created.webView.stopLoading()
                _ = workspace.closePanel(created.id, force: true)
                return nil
            }
            if announce { announcePopup(created, url: url, forInputSession: forInputSession) }
            return .opened(nil)
        }
        // WebKit loads the popup's request into the adopted web view only
        // after `createWebViewWith` returns, so the hand-over below puts the
        // session's content rules and clipboard guard on it first.
        if announce { announcePopup(created, url: url, forInputSession: forInputSession) }
        return .opened(webView)
    }

    /// Whether a popup becomes the creating session's tab, under its content
    /// rules and page clipboard guard, which must be on it before it loads.
    /// Whether the sessions are told of it (`announce`) never changes this.
    private func handsPopupsOverFirst(forInputSession: String?) -> Bool {
        forInputSession == nil && ownership.isSessionOwned && ownership.creatorSessionID != nil
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

    func handlePopup(request: URLRequest, forInputSession: String? = nil, announce: Bool = true) -> Bool {
        let handsOver = handsPopupsOverFirst(forInputSession: forInputSession)
        let announce = announce || handsOver
        guard isAttached, let panel, let url = request.url,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: panel.workspaceId)?
                .tabs.first(where: { $0.id == panel.workspaceId }),
              let pane = workspace.paneId(forPanelId: panel.id) else {
            return false
        }
        // The page controls the URL, and `navigate` loads a local file with
        // read access to its directory: a window a page opens from a tab a
        // session drives never loads one (handled: nothing opens).
        if url.scheme?.lowercased() == "file" { return true }
        // The new tab stays in the opener's profile and data store, as a
        // user's Cmd-click does (`BrowserPanel` new-tab requests): a session
        // tab on a private `session.configure({ proxy })` store keeps it.
        // A session's popup opens blank and loads only once the session's
        // content rules and clipboard guard are on it (BrowserReplPopupOpening).
        let store = panel.explicitEphemeralWebsiteDataStoreForSibling
        let profileID = panel.profileID
        let opening = BrowserReplPopupOpening<BrowserPanel>(
            create: { initialURL in
                workspace.newBrowserSurface(
                    inPane: pane,
                    url: initialURL,
                    focus: false,
                    preferredProfileID: profileID,
                    creationPolicy: .automationPreload,
                    websiteDataStore: store
                )
            },
            handOver: { [self] created in
                if announce { announcePopup(created, url: url, forInputSession: forInputSession) }
            },
            load: { created, url in created.navigate(to: url) }
        )
        return opening.open(url, handOverFirst: handsOver) != nil
    }

    // MARK: - Downloads

    /// Downloads reported to a session, by id, with that session and where
    /// each came from, judged again at each later redirect and at the end.
    private var sessionDownloads = BrowserReplSessionDownloads()

    /// Whether download `id` went to a session. Those stay in cmux's
    /// temporary download directory, so `download.path()` can read them;
    /// every other download takes the user's normal path.
    func keepsDownloadInTemporaryDirectory(id: String) -> Bool {
        sessionDownloads.sessionID(of: id) != nil
    }

    /// How a finished download goes on (``downloadDidFinish(id:path:error:)``).
    enum DownloadEnd {
        /// The user's download location: no session gets it.
        case user
        /// The session got its path; it stays in the temporary directory.
        case session
        /// Its creating session's policy or directories refuse a place it
        /// came from: the file is removed, and nobody gets it.
        case refused
    }

    private static var navigationTokenKey: UInt8 = 0
    /// Read from WebKit's download delegate, which is not main-actor bound;
    /// only its address is used.
    nonisolated(unsafe) private static var downloadClaimKey: UInt8 = 0
    private var lastNavigationToken = 0

    /// Records a navigation WebKit asks about (its navigation action) as its
    /// frame's latest, with the session whose input started it, for the
    /// download it may become
    /// (``BrowserReplTabOwnership/noteNavigationAction(_:frame:continuing:at:)``).
    /// The claim is bound to this navigation, never to its URL: a later
    /// navigation in the frame, also to the same URL, replaces it. A
    /// navigation decided again (after a hold) keeps its first record.
    func noteNavigationAction(_ action: WKNavigationAction) {
        guard let frame = Self.frameKey(action.targetFrame),
              objc_getAssociatedObject(action, &Self.navigationTokenKey) == nil else { return }
        lastNavigationToken += 1
        let token = lastNavigationToken
        objc_setAssociatedObject(action, &Self.navigationTokenKey, NSNumber(value: token), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let redirectSelector = NSSelectorFromString("_isRedirect")
        let continuing = action.responds(to: redirectSelector) && (action.value(forKey: "_isRedirect") as? Bool) == true
        ownership.noteNavigationAction(
            token,
            frame: frame,
            url: action.request.url?.absoluteString,
            initiator: action.browserReplSourceDocument,
            continuing: continuing
        )
    }

    /// Binds to `download`, which WebKit made of navigation action
    /// `action`, the session whose input started that navigation, if any,
    /// and where the navigation went.
    func claimDownload(_ download: WKDownload, fromNavigationAction action: WKNavigationAction) {
        guard let token = (objc_getAssociatedObject(action, &Self.navigationTokenKey) as? NSNumber)?.intValue else { return }
        bind(download, to: ownership.takeDownloadClaim(navigation: token))
    }

    /// Binds to `download`, which WebKit made of a navigation response in
    /// `frame`, the session whose input started that frame's latest
    /// navigation, if any, and where the navigation went.
    func claimDownload(_ download: WKDownload, fromResponse response: WKNavigationResponse) {
        let frameSelector = NSSelectorFromString("_frame")
        let info = response.responds(to: frameSelector) ? response.value(forKey: "_frame") as? WKFrameInfo : nil
        let frame = response.isForMainFrame ? "main" : Self.frameKey(info)
        guard let frame else { return }
        bind(download, to: ownership.takeDownloadClaim(responseInFrame: frame))
    }

    private func bind(_ download: WKDownload, to claim: BrowserReplDownloadClaim?) {
        guard let claim else { return }
        objc_setAssociatedObject(download, &Self.downloadClaimKey, BrowserReplDownloadClaimBox(claim), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The claim bound to `download` (``claimDownload(_:fromNavigationAction:)``).
    nonisolated private static func claimBox(of download: WKDownload) -> BrowserReplDownloadClaimBox? {
        objc_getAssociatedObject(download, &downloadClaimKey) as? BrowserReplDownloadClaimBox
    }

    /// The session whose input started the navigation `download` came from
    /// (``claimDownload(_:fromNavigationAction:)``), or `nil`.
    nonisolated static func downloadStarter(of download: WKDownload) -> String? {
        claimBox(of: download)?.claim.sessionID
    }

    /// Where `download` came from: its navigation's URLs and starter (when
    /// a navigation became it), then each redirect of the download itself
    /// (``downloadRedirected(_:to:)``).
    nonisolated static func downloadSource(of download: WKDownload) -> BrowserReplDownloadSource {
        claimBox(of: download)?.claim.source ?? BrowserReplDownloadSource()
    }

    /// Records that `download` was redirected to `url`.
    nonisolated static func downloadRedirected(_ download: WKDownload, to url: URL?) {
        guard let url else { return }
        if let box = claimBox(of: download) {
            box.went(to: url.absoluteString)
        } else {
            objc_setAssociatedObject(
                download,
                &downloadClaimKey,
                BrowserReplDownloadClaimBox(BrowserReplDownloadClaim(sessionID: nil, source: BrowserReplDownloadSource(hops: [url.absoluteString]))),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// A frame's key for its latest navigation: `main`, or WebKit's frame id.
    private static func frameKey(_ info: WKFrameInfo?) -> String? {
        guard let info else { return nil }
        return info.isMainFrame ? "main" : BrowserReplFrame.frameID(of: info)
    }

    /// Reports a download to the one session it goes to
    /// (``BrowserReplTabOwnership/downloadRoute(startedBy:source:policy:fileRoots:)``):
    /// in a user's tab only one the session's own input started, never a
    /// file the user downloads, and in any tab only one from places the
    /// session's domain policy and directories allow. The decision, and that
    /// session, hold for the download's life; any other download takes the
    /// user's normal path.
    /// - Parameters:
    ///   - startedBy: The session whose input started the navigation the
    ///     download came from (``downloadStarter(of:)``).
    ///   - source: Where the download came from (``downloadSource(of:)``),
    ///     with the response's URL last.
    ///   - url: The response's URL.
    /// - Returns: `false` when the download must be cancelled: the tab's
    ///   creating session may not read where it came from.
    @discardableResult
    func downloadDidStart(id: String, startedBy starter: String?, source: BrowserReplDownloadSource, url: URL?, suggestedFilename: String) -> Bool {
        guard isAttached else { return true }
        let route = ownership.downloadRoute(
            startedBy: starter,
            source: source,
            policy: { BrowserReplPolicyBoard.shared.policy(for: $0) },
            fileRoots: { BrowserReplPolicyBoard.shared.fileRoots(for: $0) }
        )
        switch route {
        case .user:
            return true
        case .refused(let reason):
            emit("navigation.blocked", ["url": url?.absoluteString ?? "", "reason": reason])
            return false
        case .session(let delivery):
            guard sinks[delivery.sessionID] != nil else { return true }
            let owner = delivery.sessionID
            sessionDownloads.add(id, sessionID: owner, source: source)
            let payload: [String: Any] = [
                "downloadId": id,
                "url": url?.absoluteString ?? "",
                "suggestedFilename": suggestedFilename,
            ]
            // Only the tab's creator gets the URL's credential values.
            emit("download.started", delivery.seesCredentials ? payload : payload.redactingBrowserReplCredentials(), to: owner)
            return true
        }
    }

    /// Download `id`, which went to a session, went on to `url` after WebKit
    /// picked its destination. Returns `false` when it must be cancelled: its
    /// session, the tab's creator, may not read that place. A download a
    /// session got in a user's tab goes to the user's location instead.
    /// Either way the session gets `download.finished` with the reason.
    func downloadRedirected(id: String, to url: URL?) -> Bool {
        guard let url, let refusal = sessionDownloads.redirect(
            id,
            to: url.absoluteString,
            policy: { BrowserReplPolicyBoard.shared.policy(for: $0) },
            fileRoots: { BrowserReplPolicyBoard.shared.fileRoots(for: $0) }
        ) else { return true }
        emit("download.finished", ["downloadId": id, "error": "refused: \(refusal.reason)"], to: refusal.sessionID)
        return !isLiveCreator(refusal.sessionID)
    }

    /// Reports download `id`'s end to the session it went to. A finished
    /// file's every source is judged again first, under the session's policy
    /// and directories now: one they refuse gives the session no path.
    @discardableResult
    func downloadDidFinish(id: String, path: String?, error: String?) -> DownloadEnd {
        guard let path, error == nil else {
            guard let owner = sessionDownloads.remove(id) else { return .user }
            var payload: [String: Any] = ["downloadId": id]
            if let error { payload["error"] = error }
            emit("download.finished", payload, to: owner)
            return .session
        }
        switch sessionDownloads.finish(
            id,
            policy: { BrowserReplPolicyBoard.shared.policy(for: $0) },
            fileRoots: { BrowserReplPolicyBoard.shared.fileRoots(for: $0) }
        ) {
        case .notSessions:
            return .user
        case .session(let owner):
            downloadPaths[id] = path
            emit("download.finished", ["downloadId": id, "path": path], to: owner)
            return .session
        case .refused(let owner, let reason):
            emit("download.finished", ["downloadId": id, "error": "refused: \(reason)"], to: owner)
            return isLiveCreator(owner) ? .refused : .user
        }
    }

    /// Whether `sessionID` is the tab's live creator, whose tab never keeps
    /// what its policy refuses (``BrowserReplTabOwnership/downloadRoute(startedBy:source:policy:fileRoots:)``).
    private func isLiveCreator(_ sessionID: String) -> Bool {
        ownership.isSessionOwned && ownership.creatorSessionID == sessionID
    }
}

/// The claim bound to a download, which its redirects extend. WebKit calls
/// the download delegate on the main thread, but the box is read from code
/// that is not main-actor bound, so it locks.
final class BrowserReplDownloadClaimBox: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrowserReplDownloadClaim

    init(_ claim: BrowserReplDownloadClaim) {
        stored = claim
    }

    var claim: BrowserReplDownloadClaim { lock.withLock { stored } }

    func went(to url: String) {
        lock.withLock { stored.source.went(to: url) }
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

    /// Called with the event, its payload and the document that sent it,
    /// as WebKit recorded it (the sessions whose policy blocks it get none).
    private let emit: (String, [String: Any], BrowserReplFrameDocument) -> Void

    init(emit: @escaping (String, [String: Any], BrowserReplFrameDocument) -> Void) {
        self.emit = emit
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        let document = BrowserReplFrameDocument(info: message.frameInfo)
        switch kind {
        case "console":
            emit("console", [
                "type": body["type"] as? String ?? "log",
                "text": body["text"] as? String ?? "",
            ], document)
        case "pageerror":
            emit("pageerror", [
                "message": body["message"] as? String ?? "",
                "stack": body["stack"] as? String ?? "",
            ], document)
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
