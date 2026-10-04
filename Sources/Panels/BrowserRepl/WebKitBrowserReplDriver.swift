import AppKit
import CmuxBrowser
import Network
import UniformTypeIdentifiers
import WebKit

/// JSON text returned verbatim as a driver result.
private struct BrowserReplRawJSON {
    let text: String
}

/// The `webkit` REPL driver: implements `docs/browser-repl/driver-protocol.md`
/// on cmux browser surfaces.
///
/// A session is bound to one workspace; its tabs are that workspace's
/// browser surfaces, and target ids are surface ids. Every method runs on the
/// main actor, where WebKit and AppKit live; the REPL thread awaits results.
final class WebKitBrowserReplDriver: BrowserReplDriver, @unchecked Sendable {
    let sessionID: String
    let workspaceID: UUID
    private let bundle: BrowserReplRuntimeBundle
    private let sleeper: any BrowserReplSleeping
    private let lock = NSLock()
    private var sink: BrowserReplDriverEventSink?
    /// Set by `detach()`: later calls fail and in-flight ones undo any
    /// attachment they made.
    private var isDetached = false
    /// The session's domain policy (BrowserReplDomainPolicy). Only the native
    /// session sets it, through `setDomainPolicy`.
    private var domainPolicy = BrowserReplDomainPolicy()
    /// Applies the latest policy's content rules; calls wait for it.
    private var policyTask: Task<Void, Never>?
    /// Set while WebKit refuses the latest policy's content rules: every
    /// call fails with it until a policy that compiles replaces it.
    @MainActor private var policyFailure: BrowserReplDriverError?
    /// Applies the domain policy to each frame a call reads or acts on, by
    /// WebKit's record of the frame and its document read in the driver's
    /// own content world.
    @MainActor private lazy var frameGate = BrowserReplFrameGate(world: BrowserReplDriverWorld.world)

    // Main-actor state.
    private var activeTargetID: String?
    /// Download outcomes; `download.path` reads them as state.
    @MainActor private lazy var downloads = BrowserReplDownloadLedger()
    private var dragSequence = 0
    /// Tabs this session opened (`tabs.open` and page popups). They close
    /// when the session ends unless `tab.keep` released them.
    private var openedTargetIDs: [UUID] = []
    /// `session.name` label, shown before the title of tabs this session opened.
    private var sessionLabel: String?
    /// Tabs that carry the label, including kept ones; cleared at session end.
    private var labeledTargetIDs: Set<UUID> = []
    private var fileChooserDirectories: [URL] = []
    /// `session.configure` options, applied to every tab the session drives.
    @MainActor private var contextOptions: BrowserReplContextOptions?
    /// A private, non-persistent data store that routes through
    /// `session.configure({ proxy })`; tabs the session opens use it.
    @MainActor private var proxyDataStore: WKWebsiteDataStore?

    init(
        sessionID: String,
        workspaceID: UUID,
        bundle: BrowserReplRuntimeBundle,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock())
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.bundle = bundle
        self.sleeper = sleeper
    }

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        if lock.withLock({ isDetached }) { return .failure(Self.closedError) }
        let work = Task { @MainActor in
            await self.dispatch(method: method, paramsJSON: paramsJSON)
        }
        // The session cancels in-flight calls when it closes.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static let closedError = BrowserReplDriverError(code: "closed", message: "the REPL session was closed")

    func setDomainPolicy(_ policy: BrowserReplDomainPolicy) {
        lock.lock()
        domainPolicy = policy
        let previous = policyTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyDomainPolicy(policy)
        }
        policyTask = task
        lock.unlock()
    }

    /// Puts the policy's content rules on the tabs the session created and
    /// gives the navigation guard the policy.
    @MainActor
    private func applyDomainPolicy(_ policy: BrowserReplDomainPolicy) async {
        BrowserReplNavigationGuard.shared.setPolicy(policy, sessionID: sessionID)
        frameGate.policy = policy
        var options = contextOptions ?? BrowserReplContextOptions()
        do {
            let rules = policy.contentRules
            options.ruleList = try await compileRuleList(rules.isEmpty ? nil : rules)
            policyFailure = nil
        } catch {
            // The policy is not in force for subresources, so the session
            // may not go on as if it were: its calls fail (dispatchAttached)
            // until it sets a policy that compiles. The tabs keep the last
            // rule list that compiled.
            let reason = (error as? BrowserReplDriverError)?.message ?? error.localizedDescription
            policyFailure = Self.error(
                "invalid",
                "the domain policy could not be applied: WebKit refused its content rules (\(reason)); set a policy that compiles (session.allowedDomains, session.prohibitedDomains, session.blockIPAddresses), or reset the session if the policy is locked"
            )
            return
        }
        contextOptions = options
        BrowserReplTabAttachments.shared.setContext(options, forSession: sessionID)
    }

    private var currentPolicy: BrowserReplDomainPolicy { lock.withLock { domainPolicy } }

    /// The session's own input: a dialog, file chooser or window the page
    /// opens while it handles one goes to the session. A page-world
    /// `frame.evaluate` holds that window for at most a second, and
    /// navigations until they commit (`navigate`, `history`, `reload`), so
    /// the user's own dialogs in the tab stay the user's.
    private static func isActionOnPage(_ method: String) -> Bool {
        method.hasPrefix("input.")
    }

    /// Methods that read or act on a page or its cookies; refused while the
    /// page is one the policy blocks. Of the cookie calls only
    /// `cookies.clear` takes its scope (the tab's site) from the page;
    /// `cookies.get` and `cookies.set` use the tab only to pick its data
    /// store, and are judged by their URLs and each cookie's domain, so a
    /// page that shows a blocked site does not stop an allowed cookie.
    private static func isGuarded(_ method: String) -> Bool {
        method == "frame.evaluate" || method.hasPrefix("input.") || method == "tab.screenshot"
            || method == "tab.pdf" || method.hasPrefix("clipboard.") || method == "filechooser.respond"
            || method == "cookies.clear" || method == "auth.request"
            || method == "frame.contentFrame" || method == "frame.contentFrames"
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {
        lock.withLock { sink = eventSink }
    }

    func detach() {
        lock.withLock {
            sink = nil
            isDetached = true
        }
        let sessionID = self.sessionID
        Task { @MainActor in
            BrowserReplNavigationGuard.shared.removeSession(sessionID)
            BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
            // The compiled domain-policy list must not outlive the session
            // in WebKit's persistent rule list store.
            if let ruleLists = self.ruleLists {
                Task { @MainActor in _ = try? await ruleLists.update(rules: nil) }
            }
            self.clearSessionLabels()
            self.closeOpenedTabs()
            self.releaseDownloadWaiters()
            for directory in self.fileChooserDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            self.fileChooserDirectories.removeAll()
        }
    }

    // MARK: - Dispatch

    @MainActor
    private func dispatch(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        let result = await dispatchAttached(method: method, paramsJSON: paramsJSON)
        // A call that was in flight when the session closed may have attached
        // a tab after detach() ran; take it off again.
        if lock.withLock({ isDetached }) {
            BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
            return .failure(Self.closedError)
        }
        // The store is cached per change of the typed values; the scan of
        // the result runs off the main thread.
        guard let store = BrowserReplTabAttachments.shared.typedSecrets.redaction(forReader: sessionID) else { return result }
        return await Self.maskingTypedSecrets(result, method: method, store: store)
    }

    /// A result with the secrets other sessions typed into tabs masked
    /// (``BrowserReplTypedSecrets``): this session does not hold them, so
    /// its own redaction would not. Screenshots and PDFs get them as
    /// capture masks instead (``typedSecretMasks(_:)``).
    private static func maskingTypedSecrets(
        _ result: Result<String, BrowserReplDriverError>,
        method: String,
        store: BrowserReplSecretStore
    ) async -> Result<String, BrowserReplDriverError> {
        switch result {
        case .success(let json):
            return method == "tab.screenshot" || method == "tab.pdf" ? result : .success(store.redactJSON(json))
        case .failure(let error):
            return .failure(BrowserReplDriverError(code: error.code, message: store.redact(error.message), errorName: error.errorName))
        }
    }

    /// The session's capture masks plus the secrets other sessions typed.
    @MainActor
    private func typedSecretMasks(_ params: [String: Any]) -> [[String: Any]] {
        (params["secretMasks"] as? [[String: Any]] ?? [])
            + BrowserReplTabAttachments.shared.typedSecrets.captureMasks(forReader: sessionID)
    }

    @MainActor
    private func dispatchAttached(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        if let pending = lock.withLock({ policyTask }) { await pending.value }
        if let policyFailure { return .failure(policyFailure) }
        let params = JSONSerialization.browserReplObject(paramsJSON)
        // Every call on a tab first wakes a hibernated tab and waits until
        // the tab renders like a focused foreground page; input must not race
        // WebKit's focus update. Closing or keeping a tab leaves it as it is.
        var tabToPrepare: BrowserPanel?
        if BrowserReplTabWaker.wakesHibernatedTab(method),
           let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
           let panel = try? reachablePanel(id) {
            // Attaching keeps the tab rendering, which starts the restore of
            // a hibernated page (BrowserReplTabAttachment.keepRendering).
            attach(panel)
            tabToPrepare = panel
        }
        defer {
            // A pane that shows a mirror of this tab gets the page's new look.
            if let raw = params["targetId"] as? String, let id = UUID(uuidString: raw) {
                BrowserReplTabAttachments.shared.attachment(for: id)?.pageDidChange()
            }
        }
        do {
            let started = ContinuousClock.now
            if let panel = tabToPrepare {
                // The policy judges the tab's recorded URL before a wake would
                // load a page it blocks.
                try checkPagePolicy(method: method, params: params)
                let attachment = attachment(panel)
                // A dialog the restored page opens while it loads is this
                // session's doing, as is one from its own input.
                let preparation = tabCondition(panel).state == .live
                    ? try await prepareTab(panel, for: method, params: params)
                    : try await attachment.withInput(sessionID: sessionID) {
                        try await prepareTab(panel, for: method, params: params)
                    }
                // WebKit signals the update; the bound only guards a web process
                // that goes away before answering.
                _ = await withTimeout(milliseconds: 2_000) { await attachment.renderingSettled() }
                if preparation == .reloaded {
                    // Loading the crashed or hibernated tab again was the
                    // reload; it waited for DOMContentLoaded, and `waitUntil`
                    // may ask for more within the call's timeout.
                    try await waitForLoadState(panel, Self.waitUntil(params), remainingMilliseconds: Self.remaining(Self.timeout(params), since: started))
                    var result: [String: Any] = [:]
                    if let status = attachment.mainDocumentStatus { result["status"] = status }
                    guard let json = JSONSerialization.browserReplString(result.isEmpty ? nil : result as Any?) else {
                        return .success("null")
                    }
                    return .success(json)
                }
            }
            try checkPagePolicy(method: method, params: params)
            try await checkFramePolicy(method: method, params: params)
            let value: Any?
            if Self.isActionOnPage(method), let panel = tabToPrepare {
                // What the page opens while it handles this session's input
                // goes to this session, never to cmux's UI in front of the user.
                value = try await attachment(panel).withInput(sessionID: sessionID) {
                    try await handle(method: method, params: params)
                }
            } else if method == "frame.evaluate", params["world"] as? String == "page", let panel = tabToPrepare {
                // The agent's own page script (el.click(), form.submit()):
                // what it opens goes to the session, for at most a second,
                // so a long script leaves the user's dialogs and popups alone.
                // The runtime's own reads run in the agent world and hold none.
                value = try await attachment(panel).withInput(sessionID: sessionID, atMost: .seconds(1), sleeper: sleeper) {
                    try await handle(method: method, params: params)
                }
            } else {
                value = try await handle(method: method, params: params)
            }
            if let raw = value as? BrowserReplRawJSON { return .success(raw.text) }
            guard let json = JSONSerialization.browserReplString(value) else {
                return .failure(Self.error("invalid", "Driver result for \(method) is not JSON"))
            }
            return .success(json)
        } catch let error as BrowserReplDriverError {
            return .failure(error)
        } catch {
            return .failure(Self.error("invalid", error.localizedDescription))
        }
    }

    @MainActor
    private func handle(method: String, params: [String: Any]) async throws -> Any? {
        switch method {
        case "tabs.list": return try listTabs(all: params["all"] as? Bool == true)
        case "history.search": return try searchHistory(params)
        case "tabs.dataStore": return try dataStore(params)
        case "tabs.open": return try await openTab(params)
        case "tabs.close": return try closeTab(params)
        case "tabs.activate", "tab.bringToFront": return try activateTab(params)
        case "tab.keep": return try keepTab(params)
        case "tab.handleEvents": return try handleEvents(params)
        case "session.name": return try nameSession(params)
        case "session.configure": return try await configureSession(params)
        case "tab.navigate": return try await navigate(params)
        case "tab.history": return try await history(params)
        case "tab.reload": return try await reload(params)
        case "tab.info": return try await info(params)
        case "tab.setViewport": return try setViewport(params)
        case "frames.list": return try await listFrames(params)
        case "frame.evaluate": return try await evaluate(params)
        case "frame.ownerBox": return try await ownerBox(params)
        case "frame.contentFrame": return try await contentFrame(params)
        case "frame.contentFrames": return try await contentFrames(params)
        case "input.mouse": return try await mouse(params)
        case "input.key": return try await key(params)
        case "input.insertText": return try await insertText(params)
        case "input.drag": return try await drag(params)
        case "input.setFiles": return try await setFiles(params)
        case "filechooser.respond": return try respondToFileChooser(params)
        case "dialog.respond": return try respondToDialog(params)
        case "download.path": return try await downloadPath(params)
        case "tab.screenshot": return try await screenshot(params)
        case "tab.pdf": return try await pdf(params)
        case "cookies.get": return try await cookies(params)
        case "cookies.set": return try await setCookies(params)
        case "cookies.clear": return try await clearCookies(params)
        case "clipboard.read": return try readClipboard(params)
        case "clipboard.write": return try writeClipboard(params)
        case "auth.request":
            // sites.browserAuth: a native sheet collects credentials; see BrowserReplCredentialRequest.
            let panel = try panel(params)
            let frame = try await frame(panel, params)
            // The sheet names the frame's origin as WebKit recorded it, and
            // the fill writes only into a document of that origin, so both
            // the record and the document the frame shows now must be ones
            // the domain policy allows.
            if let reason = frameGate.recordedBlockReason(of: frame, in: panel.webView) {
                throw Self.error("blocked", "the sign-in fields are in a frame showing \(frame.url), which the domain policy blocks: \(reason)")
            }
            try await frameGate.authorize(frame, in: panel.webView)
            let workspaceTitle = allBrowserPanels().first { $0.panel.id == panel.id }?.workspace.title ?? ""
            return await BrowserReplCredentialRequest.run(
                webView: panel.webView, frameInfo: frame.info, params: params,
                fillSource: bundle.readResource("sites/auth-fill.js"),
                requester: (tab: Self.title(panel), workspace: workspaceTitle)
            )
        default:
            throw Self.error("unsupported", "Unsupported driver method \(method)")
        }
    }

    static func error(_ code: String, _ message: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: code, message: message)
    }

    /// Refuses a read or input on a tab whose page the domain policy blocks,
    /// and a navigation to a blocked URL.
    @MainActor
    private func checkPagePolicy(method: String, params: [String: Any]) throws {
        let policy = currentPolicy
        guard policy.isActive else { return }
        if method == "tab.navigate" || method == "tabs.open", let url = params["url"] as? String,
           let reason = policy.blockReason(url) {
            throw Self.error("blocked", "\(url) is blocked: \(reason)")
        }
        guard Self.isGuarded(method), let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
              let panel = try? reachablePanel(id) else { return }
        // A hibernated tab has no page yet; its recorded URL is what a wake would load.
        let url = Self.url(panel)
        guard !url.isEmpty, let reason = policy.blockReason(url) else { return }
        throw Self.error("blocked", "the tab shows \(url), which the domain policy blocks: \(reason); navigate it to an allowed page")
    }

    /// After a navigation of a tab the user owns: a page the policy blocks is
    /// left in place (the user's tab is never navigated away) and the call fails.
    @MainActor
    private func checkLandedPage(_ panel: BrowserPanel) throws {
        let policy = currentPolicy
        guard policy.isActive, let url = panel.webView.url?.absoluteString,
              let reason = policy.blockReason(url) else { return }
        throw Self.error("blocked", "navigation to \(url) was blocked: \(reason); the tab is the user's, so it stays there and the session cannot read it")
    }

    /// Refuses input and captures that would reach a frame (not only the
    /// main frame) the domain policy blocks, judged on the frame tree as it
    /// is now. Calls that run script in one frame are judged where they run
    /// (`BrowserReplFrameGate.callAsyncJavaScript`).
    @MainActor
    private func checkFramePolicy(method: String, params: [String: Any]) async throws {
        guard currentPolicy.isActive,
              ["input.mouse", "input.drag", "input.key", "input.insertText", "tab.screenshot", "tab.pdf", "filechooser.respond"].contains(method),
              let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
              let panel = try? reachablePanel(id) else { return }
        if method == "filechooser.respond", params["cancel"] as? Bool == true { return }
        let webView = panel.webView
        let frames = await BrowserReplFrameTree.frames(of: webView)
        switch method {
        case "input.mouse":
            let position = BrowserReplTabAttachments.shared.attachment(for: id)?.mousePosition ?? .zero
            let point = CGPoint(
                x: (params["x"] as? NSNumber)?.doubleValue ?? position.x,
                y: (params["y"] as? NSNumber)?.doubleValue ?? position.y
            )
            try await frameGate.checkPointer(at: [point], in: webView, frames: frames)
        case "input.drag":
            try await frameGate.checkPointer(at: Self.dragTrail(params), in: webView, frames: frames)
        case "input.key", "input.insertText":
            try await frameGate.checkFocus(in: webView, frames: frames)
        case "filechooser.respond":
            // Files go only to the input of the chooser's own frame.
            guard let chooserID = params["chooserId"] as? String,
                  let frame = BrowserReplTabAttachments.shared.attachment(for: id)?.fileChooserFrame(id: chooserID, sessionID: sessionID) else {
                return
            }
            try await frameGate.checkFileChooser(frame: frame, in: webView, frames: frames)
        case "tab.screenshot":
            // Judged during the capture, which blanks blocked frames
            // (BrowserReplFrameGate.coverBlockedFrames).
            return
        default:
            // A PDF is laid out for print; its frames' boxes cannot be
            // blanked, so any blocked frame refuses it.
            try frameGate.checkCapture(in: webView, frames: frames)
        }
    }

    // MARK: - Tabs

    @MainActor
    private func workspace() throws -> Workspace {
        guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?
            .tabs.first(where: { $0.id == workspaceID }) else {
            throw Self.error("closed", "The workspace this REPL session is bound to is closed")
        }
        return workspace
    }

    @MainActor
    private func browserPanels() throws -> [BrowserPanel] {
        let workspace = try workspace()
        return workspace.orderedPanelIds.compactMap { workspace.panels[$0] as? BrowserPanel }
    }

    /// Resolves `targetId` to an attached browser panel.
    @MainActor
    private func panel(_ params: [String: Any]) throws -> BrowserPanel {
        let panel = try existingPanel(params)
        attach(panel).keepRendering()
        return panel
    }

    /// Resolves `targetId` without attaching to it or waking it.
    @MainActor
    private func existingPanel(_ params: [String: Any]) throws -> BrowserPanel {
        guard let raw = params["targetId"] as? String, let id = UUID(uuidString: raw) else {
            throw Self.error("invalid", "targetId is required")
        }
        guard let panel = try reachablePanel(id) else {
            throw Self.error("closed", "Tab \(raw) is closed")
        }
        return panel
    }

    /// Browser surfaces in every workspace of every window, with the
    /// workspace that holds each.
    @MainActor
    private func allBrowserPanels() -> [(panel: BrowserPanel, workspace: Workspace)] {
        guard let app = AppDelegate.shared else { return [] }
        var out: [(BrowserPanel, Workspace)] = []
        var seen = Set<UUID>()
        for context in app.mainWindowContexts.values.sorted(by: { $0.windowId.uuidString < $1.windowId.uuidString }) {
            for workspace in context.tabManager.tabs where seen.insert(workspace.id).inserted {
                for id in workspace.orderedPanelIds {
                    if let panel = workspace.panels[id] as? BrowserPanel { out.append((panel, workspace)) }
                }
            }
        }
        return out
    }

    /// A tab this session may drive: one of its workspace's browser surfaces,
    /// or a tab in another workspace it claimed with tabs.use(id) after
    /// `tabs.list({ all: true })` listed it (reference B's claimTab).
    @MainActor
    private func reachablePanel(_ id: UUID) throws -> BrowserPanel? {
        if let own = try browserPanels().first(where: { $0.id == id }) { return own }
        if let other = allBrowserPanels().first(where: { $0.panel.id == id })?.panel { return other }
        // A tab a relaunch restored but has not loaded yet is a placeholder
        // until first use; using it creates its browser, which then loads
        // like a hibernated tab (prepareTab). Creating it shows nothing.
        for workspace in allWorkspaces() {
            if let deferred = workspace.panels[id] as? DeferredBrowserPanel {
                return workspace.materializeDeferredBrowserPanel(deferred)
            }
        }
        return nil
    }

    /// Every workspace of every window, the session's own first.
    @MainActor
    private func allWorkspaces() -> [Workspace] {
        let own = try? workspace()
        var out: [Workspace] = own.map { [$0] } ?? []
        guard let app = AppDelegate.shared else { return out }
        for context in app.mainWindowContexts.values.sorted(by: { $0.windowId.uuidString < $1.windowId.uuidString }) {
            for workspace in context.tabManager.tabs where !out.contains(where: { $0.id == workspace.id }) {
                out.append(workspace)
            }
        }
        return out
    }

    /// `tabs.list` rows for a relaunch's not-yet-loaded tabs of `workspace`,
    /// by panel id: they list as hibernated, and listing does not load them.
    @MainActor
    private static func deferredTabRows(_ workspace: Workspace) -> [UUID: [String: Any]] {
        var rows: [UUID: [String: Any]] = [:]
        for id in workspace.orderedPanelIds {
            guard let deferred = workspace.panels[id] as? DeferredBrowserPanel else { continue }
            rows[id] = [
                "targetId": id.uuidString,
                "title": deferred.sessionPanelSnapshot.title ?? "",
                "url": deferred.sessionPanelSnapshot.browser?.urlString ?? "",
                "active": false,
                "windowId": workspace.id.uuidString,
                "state": BrowserReplTabState.hibernated.rawValue,
            ]
        }
        return rows
    }

    /// What the REPL reports about the tab's web content (`tabs.list`, `tab.info`).
    @MainActor
    private func tabCondition(_ panel: BrowserPanel) -> BrowserReplTabCondition {
        let discard = panel.hiddenWebViewDiscardManager
        let isHibernated = discard.isDiscardedForMemory
        return BrowserReplTabCondition(
            isHibernated: isHibernated,
            isWaking: isHibernated && (discard.isRestoreNavigationPending || panel.hasPendingRemoteNavigation || panel.webView.isLoading),
            isCrashed: panel.webContentState.isTerminated,
            restoreStoppedByUser: panel.userStoppedLoadSinceWebViewReplacement
        )
    }

    /// The tab's title for the agent: the page's, else the one cmux kept
    /// while the page is unloaded.
    @MainActor
    private static func title(_ panel: BrowserPanel) -> String {
        if let title = panel.webView.title, !title.isEmpty { return title }
        return panel.pageTitle
    }

    @MainActor
    private static func url(_ panel: BrowserPanel) -> String {
        panel.webView.url?.absoluteString ?? panel.currentURL?.absoluteString ?? ""
    }

    /// Wakes a hibernated tab before `method` and waits, at most
    /// ``BrowserReplTabWaker/defaultTimeout``, for its page to load again,
    /// or fails with why the tab cannot run it (crashed, a restore the user
    /// stopped). Waking renders the tab off screen; it never shows or
    /// focuses it.
    @MainActor
    private func prepareTab(_ panel: BrowserPanel, for method: String, params: [String: Any]) async throws -> BrowserReplTabPreparation {
        let label = BrowserReplTabLabel(id: panel.id.uuidString, title: Self.title(panel), url: Self.url(panel))
        // A reload keeps its own timeout; other calls get the wake's bound.
        let timeout: Duration = method == "tab.reload" ? .milliseconds(Self.timeout(params)) : BrowserReplTabWaker.defaultTimeout
        return try await BrowserReplTabWaker(sleeper: sleeper, timeout: timeout).prepare(
            method: method,
            tab: label,
            condition: { self.tabCondition(panel) },
            wake: { self.attachment(panel).keepRendering() },
            recoverCrash: {
                // As the pane's Reload does: a new web content process loads
                // the page into a new web view, off screen.
                _ = panel.recoverTerminatedWebContent(reason: "browser.repl.reload")
                self.attachment(panel).keepRendering()
            },
            waitUntilLoaded: { [self] in
                // The page commits into the web view the discard or the crash
                // recovery put in place; one replaced again meanwhile is waited for too.
                let committed = await BrowserReplTabWaker.waitForPageCommit(
                    instance: { panel.webViewInstanceID },
                    waitForCommit: { await panel.automationDocumentReadiness.waitForCommit(instanceID: $0) }
                )
                guard committed, !panel.hiddenWebViewDiscardManager.isDiscardedForMemory, !Task.isCancelled else { return }
                try? await self.waitForLoadState(panel, "domcontentloaded", remainingMilliseconds: Int(BrowserReplTabWaker.defaultTimeout.components.seconds) * 1000)
            }
        )
    }

    @MainActor
    @discardableResult
    private func attach(_ panel: BrowserPanel) -> BrowserReplTabAttachment {
        // The tab carries this session's options only if this session
        // created it (BrowserReplTabAttachment.contextOptions).
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { [weak self] name, payload in
            self?.forward(name, payload)
        }
    }

    /// `session.configure`: Playwright browser-context options for the tabs
    /// this session created (a user's tab it drives keeps its own). Each
    /// given key replaces the previous value; a `null` clears it. `{ userAgent, extraHTTPHeaders, permissions, proxy }`
    /// (the domain policy's content rules come from `setDomainPolicy`); `proxy` is
    /// `{ server: "http://host:port" | "socks5://host:port", username?,
    /// password?, bypass? }` and applies to tabs opened afterwards, which use
    /// a private data store (no profile cookies).
    @MainActor
    private func configureSession(_ params: [String: Any]) async throws -> Any? {
        var options = contextOptions ?? BrowserReplContextOptions()
        if params.keys.contains("userAgent") {
            let value = params["userAgent"] as? String
            options.userAgent = (value?.isEmpty ?? true) ? nil : value
        }
        if params.keys.contains("extraHTTPHeaders") {
            var headers: [String: String] = [:]
            for (name, value) in params["extraHTTPHeaders"] as? [String: Any] ?? [:] {
                guard let value = value as? String else {
                    throw Self.error("invalid", "extraHTTPHeaders: the value of \(name) must be a string")
                }
                headers[name] = value
            }
            options.extraHTTPHeaders = headers
        }
        if params.keys.contains("permissions") {
            let names = params["permissions"] as? [String] ?? []
            let known: Set<String> = ["camera", "microphone", "geolocation", "notifications"]
            if let unknown = names.first(where: { !known.contains($0) }) {
                throw Self.error("unsupported", "permissions: \(unknown) cannot be granted in WebKit; supported: camera, microphone, geolocation, notifications")
            }
            options.permissions = Set(names)
        }
        if params.keys.contains("contentRules") {
            // Content rules come from the session's domain policy
            // (setDomainPolicy), never from the REPL's JavaScript.
            throw Self.error("invalid", "session.configure: content rules come from the domain policy")
        }
        if params.keys.contains("proxy") {
            proxyDataStore = try Self.proxyDataStore(params["proxy"] as? [String: Any])
        }
        contextOptions = options
        BrowserReplTabAttachments.shared.setContext(options, forSession: sessionID)
        return ["proxy": proxyDataStore != nil]
    }

    /// Compiles the session's rule list; empty or `null` rules remove the
    /// stored one.
    @MainActor
    private func compileRuleList(_ rules: Any?) async throws -> WKContentRuleList? {
        if ruleLists == nil, (rules as? [Any])?.isEmpty ?? true { return nil }
        return try await contentRuleLists().update(rules: rules)
    }

    /// The session's compiled domain-policy rule list in WebKit's store.
    @MainActor private var ruleLists: BrowserReplContentRuleLists?

    @MainActor
    private func contentRuleLists() throws -> BrowserReplContentRuleLists {
        if let ruleLists { return ruleLists }
        guard let store = WKContentRuleListStore.default() else {
            throw Self.error("unsupported", "WebKit content rule lists are unavailable")
        }
        let lists = BrowserReplContentRuleLists(sessionID: sessionID, store: store)
        ruleLists = lists
        return lists
    }

    /// A non-persistent data store whose connections go through `proxy`, or
    /// `nil` to clear it.
    @MainActor
    private static func proxyDataStore(_ proxy: [String: Any]?) throws -> WKWebsiteDataStore? {
        guard let proxy, let server = proxy["server"] as? String, !server.isEmpty else { return nil }
        let raw = server.contains("://") ? server : "http://\(server)"
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            throw Self.error("invalid", "proxy.server: expected http://host:port or socks5://host:port, got \(server)")
        }
        let scheme = url.scheme?.lowercased() ?? "http"
        let defaultPort: UInt16 = scheme == "socks5" ? 1080 : (scheme == "https" ? 443 : 80)
        guard let port = NWEndpoint.Port(rawValue: url.port.map { UInt16(clamping: $0) } ?? defaultPort) else {
            throw Self.error("invalid", "proxy.server: bad port in \(server)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var configuration: ProxyConfiguration
        switch scheme {
        case "socks5": configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case "http", "https": configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: scheme == "https" ? .init() : nil)
        default: throw Self.error("unsupported", "proxy.server: \(scheme) proxies are not supported; use http, https or socks5")
        }
        if let username = proxy["username"] as? String, !username.isEmpty {
            configuration.applyCredential(username: username, password: proxy["password"] as? String ?? "")
        }
        if let bypass = proxy["bypass"] as? String {
            configuration.excludedDomains = bypass.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [configuration]
        BrowserReplProxyStores.register(store)
        return store
    }

    @MainActor
    private func attachment(_ panel: BrowserPanel) -> BrowserReplTabAttachment {
        BrowserReplTabAttachments.shared.attachment(for: panel.id) ?? attach(panel)
    }

    @MainActor
    private func forward(_ name: String, _ payload: [String: Any]) {
        if name == "download.finished", let id = payload["downloadId"] as? String {
            downloads.finish(id: id, path: payload["path"] as? String, error: payload["error"] as? String)
        }
        if name == "tab.created", let id = payload["targetId"] as? String, payload["openerTargetId"] != nil {
            activeTargetID = id
            // A popup of a user's tab (`userOwned`) stays the user's: it is
            // neither labelled nor closed when the session ends.
            if payload["userOwned"] as? Bool != true, let uuid = UUID(uuidString: id) {
                openedTargetIDs.append(uuid)
                applySessionLabel(to: uuid)
            }
        }
        // Events carry no secret another session typed (BrowserReplTypedSecrets).
        let visible = BrowserReplTabAttachments.shared.typedSecrets.redaction(forReader: sessionID)
            .map { $0.redactValue(payload) } ?? payload
        guard let json = JSONSerialization.browserReplString(visible) else { return }
        let sink = lock.withLock { self.sink }
        sink?(name, json)
    }

    @MainActor
    private func listTabs(all: Bool = false) throws -> [[String: Any]] {
        let workspace = try workspace()
        let panels = try browserPanels()
        if all {
            // The session's own workspace first, then every other workspace.
            let own = try listTabs()
            var others: [[String: Any]] = []
            for other in allWorkspaces() where other.id != workspace.id {
                let deferred = Self.deferredTabRows(other)
                for id in other.orderedPanelIds {
                    if let row = deferred[id] {
                        others.append(row)
                    } else if let panel = other.panels[id] as? BrowserPanel {
                        others.append([
                            "targetId": panel.id.uuidString,
                            "title": Self.title(panel),
                            "url": Self.url(panel),
                            "active": false,
                            "windowId": other.id.uuidString,
                            "state": tabCondition(panel).state.rawValue,
                            "dataStore": Self.dataStoreID(panel.webView.configuration.websiteDataStore),
                        ])
                    }
                }
            }
            return own + others
        }
        let active = activeTargetID.flatMap(UUID.init(uuidString:)).flatMap { id in panels.first { $0.id == id } }
            ?? panels.first { $0.id == workspace.focusedPanelId }
        let deferred = Self.deferredTabRows(workspace)
        guard deferred.isEmpty else {
            // A relaunch's not-yet-loaded tabs list in their places, hibernated.
            let live = Dictionary(uniqueKeysWithValues: listTabsLoaded(panels, workspace: workspace, active: active).map { ($0["targetId"] as? String ?? "", $0) })
            return workspace.orderedPanelIds.compactMap { live[$0.uuidString] ?? deferred[$0] }
        }
        return listTabsLoaded(panels, workspace: workspace, active: active)
    }

    @MainActor
    private func listTabsLoaded(_ panels: [BrowserPanel], workspace: Workspace, active: BrowserPanel?) -> [[String: Any]] {
        panels.map { panel in
            var entry: [String: Any] = [
                "targetId": panel.id.uuidString,
                "title": Self.title(panel),
                "url": Self.url(panel),
                "active": panel.id == active?.id,
                "windowId": workspace.id.uuidString,
                "state": tabCondition(panel).state.rawValue,
                "dataStore": Self.dataStoreID(panel.webView.configuration.websiteDataStore),
            ]
            if let opener = BrowserReplTabAttachments.shared.attachment(for: panel.id)?.openerTargetID {
                entry["openerTargetId"] = opener
            }
            return entry
        }
    }

    @MainActor
    private func openTab(_ params: [String: Any]) async throws -> [String: Any] {
        let workspace = try workspace()
        // A tab the session opens gets the page clipboard guard; without its
        // script, or without WebKit's switch for the asynchronous Clipboard
        // API, no page may run in such a tab.
        guard BrowserReplPageClipboard.isSupported else {
            throw Self.error("unsupported", "This WebKit cannot turn its asynchronous Clipboard API off, so a page in a tab the session opens could write the system clipboard; tabs.open is refused")
        }
        if BrowserReplTabAttachments.shared.pageClipboard == nil {
            guard let shim = bundle.readResource("page-clipboard.js") else {
                throw Self.error("unsupported", "The browser REPL page clipboard script is not bundled")
            }
            BrowserReplTabAttachments.shared.pageClipboard = BrowserReplPageClipboard(shim: shim)
        }
        let rawURL = params["url"] as? String
        // `dataStore` (an id from tabs.list or tabs.dataStore) opens the tab
        // in that store and its tab's profile, as storage state restores
        // localStorage into the store of the page it names.
        let (store, profileID) = try dataStoreForNewTab(params["dataStore"])
        // Open blank and attach first, then navigate like tab.navigate, so the
        // first navigation already sees the REPL session (for example, it skips
        // the insecure-HTTP prompt that nobody can answer).
        let url = URL(string: "about:blank")
        let paneID = workspace.focusedPanelId.flatMap { workspace.paneId(forPanelId: $0) }
            ?? workspace.bonsplitController.focusedPaneId
        guard let paneID,
              let panel = workspace.newBrowserSurface(
                  inPane: paneID,
                  url: url,
                  focus: false,
                  preferredProfileID: profileID,
                  creationPolicy: .automationPreload,
                  websiteDataStore: store
              ) else {
            throw Self.error("invalid", "Could not open a browser tab")
        }
        attach(panel).markCreated(by: sessionID)
        openedTargetIDs.append(panel.id)
        applySessionLabel(to: panel.id)
        if params["background"] as? Bool != true {
            activeTargetID = panel.id.uuidString
        }
        _ = await withTimeout(milliseconds: 30_000) {
            await panel.automationDocumentReadiness.waitForCommit(instanceID: panel.webViewInstanceID)
        }
        if let rawURL, rawURL != "about:blank" {
            _ = try await navigate([
                "targetId": panel.id.uuidString,
                "url": rawURL,
                "waitUntil": "commit",
                "timeoutMs": params["timeoutMs"] ?? 30_000,
            ])
        }
        return ["targetId": panel.id.uuidString]
    }

    /// An opaque id for `store`, equal for tabs that share cookies and
    /// storage (`tabs.list`, `tabs.dataStore`), for the life of the store
    /// and never reused (`WKWebsiteDataStore.browserReplID`).
    @MainActor
    static func dataStoreID(_ store: WKWebsiteDataStore) -> String {
        store.browserReplID
    }

    /// `tabs.dataStore`: the store cookie calls with these params use.
    @MainActor
    private func dataStore(_ params: [String: Any]) throws -> [String: Any] {
        let store = try cookieTab(params).store
        return ["dataStore": Self.dataStoreID(store)]
    }

    /// The store and profile `tabs.open` uses: the session's proxy store
    /// (or the default profile's) without `dataStore`, else the store a
    /// session-reachable tab with that id uses, and that tab's profile.
    @MainActor
    private func dataStoreForNewTab(_ raw: Any?) throws -> (WKWebsiteDataStore?, UUID?) {
        guard let raw else { return (proxyDataStore, nil) }
        guard let id = raw as? String else {
            throw Self.error("invalid", "tabs.open: dataStore must be a string from tabs.list or tabs.dataStore")
        }
        if let proxyDataStore, Self.dataStoreID(proxyDataStore) == id { return (proxyDataStore, nil) }
        if let panel = allBrowserPanels().map({ $0.panel }).first(where: { Self.dataStoreID($0.webView.configuration.websiteDataStore) == id }) {
            return (panel.webView.configuration.websiteDataStore, panel.profileID)
        }
        let defaultStore = try cookieTab([:]).store
        if Self.dataStoreID(defaultStore) == id { return (defaultStore, nil) }
        throw Self.error("invalid", "tabs.open: no open tab uses data store \(id)")
    }

    @MainActor
    private func closeTab(_ params: [String: Any]) throws -> Any? {
        let panel = try existingPanel(params)
        if params["runBeforeUnload"] as? Bool == true {
            let selector = NSSelectorFromString("_tryClose")
            if panel.webView.responds(to: selector) {
                // WebKit runs beforeunload, then asks the UI delegate to close
                // the web view, which closes the surface.
                panel.webView.perform(selector)
                return nil
            }
        }
        let workspace = try workspace()
        BrowserReplTabAttachments.shared.panelDidClose(panel.id)
        _ = workspace.closePanel(panel.id, force: true)
        if activeTargetID == panel.id.uuidString { activeTargetID = nil }
        return nil
    }

    /// `tab.handleEvents`: the events this session has a handler for in the
    /// tab. In a user's tab only those reach the session; the rest keep
    /// cmux's own UI (``BrowserReplTabOwnership``).
    @MainActor
    private func handleEvents(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
        guard let names = params["events"] as? [String],
              let events = BrowserReplTabOwnership.events(named: names) else {
            throw Self.error("invalid", "tab.handleEvents: events must be an array of \(BrowserReplTabEvent.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        attachment(panel).setHandledEvents(events, sessionID: sessionID)
        return nil
    }

    /// `tab.keep`: the tab stays open after the session ends.
    @MainActor
    private func keepTab(_ params: [String: Any]) throws -> Any? {
        let panel = try existingPanel(params)
        openedTargetIDs.removeAll { $0 == panel.id }
        return nil
    }

    /// `session.name`: labels the tabs this session opened, now and later,
    /// as `<name> · <page title>`. A title the user set still wins, and the
    /// plain title returns when the session ends.
    @MainActor
    private func nameSession(_ params: [String: Any]) throws -> Any? {
        let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sessionLabel = name.isEmpty ? nil : name
        for id in openedTargetIDs { applySessionLabel(to: id) }
        return nil
    }

    @MainActor
    private func applySessionLabel(to panelID: UUID) {
        guard let workspace = try? workspace() else { return }
        workspace.setPanelAutomationLabel(panelId: panelID, label: sessionLabel)
        if sessionLabel == nil { labeledTargetIDs.remove(panelID) } else { labeledTargetIDs.insert(panelID) }
    }

    @MainActor
    private func clearSessionLabels() {
        let labeled = labeledTargetIDs
        labeledTargetIDs.removeAll()
        guard let workspace = try? workspace() else { return }
        for id in labeled { workspace.setPanelAutomationLabel(panelId: id, label: nil) }
    }

    @MainActor
    private func activateTab(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
        let workspace = try workspace()
        activeTargetID = panel.id.uuidString
        if let tabID = workspace.surfaceIdFromPanelId(panel.id) {
            workspace.bonsplitController.selectTab(tabID)
        }
        return nil
    }

    // MARK: - Navigation

    @MainActor
    private func navigate(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        guard let raw = params["url"] as? String, let url = URL(string: raw) else {
            throw Self.error("invalid", "Invalid URL")
        }
        let timeout = Self.timeout(params)
        let started = ContinuousClock.now
        attachment(panel).rememberCredentials(in: url)
        _ = attachment(panel).takeAuthenticationFailure()
        // Until the navigation commits, a dialog the page opens (beforeunload)
        // is this session's doing; while the new page loads, it is not.
        let outcome = try await attachment(panel).withInput(sessionID: sessionID) {
            let ticket = panel.beginAutomationNavigation(to: url, recordTypedNavigation: false)
            return try await withTimeoutThrowing(milliseconds: timeout, what: "navigating to \"\(raw)\"") {
                await panel.finishAutomationNavigation(ticket)
            }
        }
        do {
            try Self.check(outcome, url: raw)
        } catch {
            if let reason = attachment(panel).takeAuthenticationFailure() { throw Self.error("invalid", reason) }
            throw error
        }
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
        try checkLandedPage(panel)
        var result: [String: Any] = ["url": panel.webView.url?.absoluteString ?? raw]
        if let status = attachment(panel).mainDocumentStatus { result["status"] = status }
        return result
    }

    @MainActor
    private func history(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let delta = (params["delta"] as? NSNumber)?.intValue ?? -1
        let webView = panel.webView
        guard let item = delta < 0 ? webView.backForwardList.backItem : webView.backForwardList.forwardItem else {
            return nil
        }
        // The blank page a tab opened on (tabs.open loads about:blank before
        // its first navigation) is not an entry to go back to, as in Chrome.
        if delta < 0, item.url.absoluteString == "about:blank", webView.backForwardList.backList.count == 1 {
            return nil
        }
        let timeout = Self.timeout(params)
        let started = ContinuousClock.now
        let outcome = try await attachment(panel).withInput(sessionID: sessionID) {
            let ticket = panel.automationNavigationCoordinator.begin(
                instanceID: panel.webViewInstanceID,
                targetURL: item.url,
                allowsSameDocumentCompletion: true
            )
            let navigation = delta < 0 ? webView.goBack() : webView.goForward()
            panel.automationNavigationCoordinator.didStart(ticket, navigationID: navigation.map { ObjectIdentifier($0) })
            return try await withTimeoutThrowing(milliseconds: timeout, what: "navigating history") {
                await panel.finishAutomationNavigation(ticket)
            }
        }
        try Self.check(outcome, url: item.url.absoluteString)
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
        return ["url": webView.url?.absoluteString ?? item.url.absoluteString]
    }

    @MainActor
    private func reload(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let timeout = Self.timeout(params)
        let started = ContinuousClock.now
        let (outcome, target) = try await attachment(panel).withInput(sessionID: sessionID) {
            guard let (ticket, target) = panel.beginAutomationReloadFromCLI() else {
                throw Self.error("invalid", "Nothing to reload")
            }
            let outcome = try await withTimeoutThrowing(milliseconds: timeout, what: "reloading") {
                await panel.finishAutomationNavigation(ticket)
            }
            return (outcome, target)
        }
        try Self.check(outcome, url: target.absoluteString)
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
        // Like goto, reload answers with the main document's HTTP status.
        if let status = attachment(panel).mainDocumentStatus { return ["status": status] }
        return nil
    }

    private static func check(_ outcome: BrowserAutomationNavigationOutcome, url: String) throws {
        switch outcome {
        case .committed, .downloaded:
            return
        case .failed(let message):
            throw error("invalid", "\(message) at \(url)")
        case .timedOut:
            throw error("timeout", "Navigation to \"\(url)\" timed out")
        case .cancelled, .superseded, .notStarted:
            throw error("invalid", "Navigation to \"\(url)\" was interrupted by another navigation")
        }
    }

    private static func waitUntil(_ params: [String: Any]) -> String {
        params["waitUntil"] as? String ?? "load"
    }

    private static func timeout(_ params: [String: Any]) -> Int {
        let value = (params["timeoutMs"] as? NSNumber)?.intValue ?? 30_000
        return value <= 0 ? 24 * 60 * 60 * 1000 : value
    }

    private static func remaining(_ timeout: Int, since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let elapsedMilliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return max(1, timeout - elapsedMilliseconds)
    }

    /// Waits until the tab's main document reaches `state`.
    @MainActor
    private func waitForLoadState(_ panel: BrowserPanel, _ state: String, remainingMilliseconds: Int) async throws {
        let script: String
        switch state {
        case "commit":
            return
        case "domcontentloaded":
            script = """
            if (document.readyState === "loading") {
              await new Promise((resolve) => document.addEventListener("DOMContentLoaded", resolve, { once: true }));
            }
            return document.readyState;
            """
        default:
            script = """
            if (document.readyState !== "complete") {
              await new Promise((resolve) => window.addEventListener("load", resolve, { once: true }));
            }
            return document.readyState;
            """
        }
        try await withTimeoutThrowing(milliseconds: remainingMilliseconds, what: "waiting for \(state)") { [self] in
            // A navigation that replaces the document mid-wait fails the
            // evaluation; retry against the new document.
            for _ in 0..<50 {
                do {
                    _ = try await panel.webView.callAsyncJavaScript(
                        script,
                        arguments: [:],
                        in: nil,
                        contentWorld: BrowserReplAgentWorld.world
                    )
                    break
                } catch {
                    if Task.isCancelled { return }
                    _ = await panel.automationDocumentReadiness.waitForCommit(instanceID: panel.webViewInstanceID)
                }
            }
            if state == "networkidle" {
                await self.waitForNetworkIdle(panel)
            }
        }
    }

    /// Playwright's `networkidle`: no request in flight for 500 ms.
    @MainActor
    private func waitForNetworkIdle(_ panel: BrowserPanel) async {
        let attachment = attachment(panel)
        while !Task.isCancelled {
            await attachment.waitForNoInflightRequests()
            let generation = attachment.requestGeneration
            do {
                try await sleeper.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            if attachment.inflightRequestCount ?? 0 == 0, attachment.requestGeneration == generation {
                return
            }
        }
    }

    @MainActor
    private func info(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        let attachment = attachment(panel)
        let webView = panel.webView
        let fallbackSize = panel.visualAutomationViewportSize()
        var result: [String: Any] = attachment.lastInfo ?? [
            "loadState": webView.isLoading ? "commit" : "load",
            "viewport": ["width": Int(fallbackSize.width), "height": Int(fallbackSize.height)],
            "deviceScaleFactor": 1,
        ]
        result["url"] = Self.url(panel)
        result["title"] = Self.title(panel)
        result["state"] = tabCondition(panel).state.rawValue
        // The web content process's pid (WKWebView SPI), so a test can end
        // that process and check crash recovery.
        let pidSelector = NSSelectorFromString("_webProcessIdentifier")
        if webView.responds(to: pidSelector), let pid = webView.value(forKey: "_webProcessIdentifier") as? NSNumber, pid.intValue > 0 {
            result["webProcessId"] = pid.intValue
        } else {
            result.removeValue(forKey: "webProcessId")
        }
        // Page script is blocked while a dialog is open; answer from native state.
        guard !attachment.hasPendingDialog else { return result }
        let metrics = await withTimeout(milliseconds: 2_000) { () -> [Any]? in
            let value = try? await webView.callAsyncJavaScript(
                "return [document.readyState === 'complete' ? 2 : document.readyState === 'interactive' ? 1 : 0, innerWidth, innerHeight, location.href, document.title];",
                arguments: [:],
                in: nil,
                contentWorld: BrowserReplAgentWorld.world
            )
            return value as? [Any]
        } ?? nil
        guard let metrics, metrics.count == 5,
              let ready = metrics[0] as? NSNumber,
              let width = metrics[1] as? NSNumber,
              let height = metrics[2] as? NSNumber,
              let href = metrics[3] as? String else { return result }
        // The live document answers url, title and readyState (pushState
        // included). While a new main-frame navigation has not committed,
        // WKWebView.url already names the next page but the document is the
        // old one; report "commit" so load-state waits hold until it lands.
        let pendingURL = webView.isLoading ? webView.url?.absoluteString : nil
        let navigationPending = pendingURL.map { $0 != href } ?? false
        result["url"] = href
        result["title"] = metrics[4] as? String ?? result["title"]
        result["loadState"] = navigationPending
            ? "commit"
            : ["commit", "domcontentloaded", "load"][max(0, min(2, ready.intValue))]
        result["viewport"] = ["width": width.intValue, "height": height.intValue]
        attachment.lastInfo = result
        return result
    }

    /// cmux browser history, most recent first, from the history stores of
    /// the profiles this workspace's tabs use (the default profile when it
    /// has none).
    @MainActor
    private func searchHistory(_ params: [String: Any]) throws -> [[String: Any]] {
        var stores: [BrowserHistoryStore] = []
        for panel in try browserPanels() where !stores.contains(where: { $0 === panel.historyStore }) {
            stores.append(panel.historyStore)
        }
        if stores.isEmpty {
            stores.append(BrowserProfileStore.shared.historyStore(for: BrowserProfileStore.shared.builtInDefaultProfileID))
        }
        let queries = (params["queries"] as? [String] ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        let from = (params["from"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let to = (params["to"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let limit = max(1, (params["limit"] as? NSNumber)?.intValue ?? 100)
        var rows: [BrowserHistoryStore.Entry] = []
        for store in stores {
            store.loadIfNeeded()
            rows.append(contentsOf: store.entries)
        }
        let matched = rows
            .filter { entry in
                if let from, entry.lastVisited < from { return false }
                if let to, entry.lastVisited > to { return false }
                guard !queries.isEmpty else { return true }
                let url = entry.url.lowercased()
                let title = (entry.title ?? "").lowercased()
                return queries.contains { url.contains($0) || title.contains($0) }
            }
            .sorted { $0.lastVisited > $1.lastVisited }
        return matched.prefix(limit).map { entry in
            [
                "url": entry.url,
                "title": entry.title ?? "",
                "dateVisited": Int(entry.lastVisited.timeIntervalSince1970 * 1000),
            ]
        }
    }

    @MainActor
    private func setViewport(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
        let viewport: BrowserViewport?
        if params["reset"] as? Bool == true {
            viewport = nil
        } else {
            let width = (params["width"] as? NSNumber)?.intValue ?? 0
            let height = (params["height"] as? NSNumber)?.intValue ?? 0
            guard let requested = BrowserViewport(width: width, height: height) else {
                throw Self.error("invalid", "Viewport \(width)x\(height) is out of range")
            }
            viewport = requested
        }
        if case .failure(let failure) = panel.setAutomationViewport(viewport) {
            throw Self.error("unsupported", "\(failure)")
        }
        return nil
    }

    // MARK: - Frames and scripts

    @MainActor
    private func listFrames(_ params: [String: Any]) async throws -> [[String: Any]] {
        let panel = try panel(params)
        let frames = await BrowserReplFrameTree.frames(of: panel.webView)
        let webView = panel.webView
        // Names are read all at once: frames in other web processes answer
        // in parallel instead of one after another (401 frames, 100 ms).
        // WebKit drops the completion of a script whose document a navigation
        // replaces (a click on a link, then frames.list), so a read that does
        // not answer falls back to the tree's name, as tab.info does.
        // A frame the domain policy blocks is not read (frameGate).
        let names = frames.map { frame in
            Task { @MainActor [self] in
                await withTimeout(milliseconds: 2_000) {
                    (try? await self.frameGate.callAsyncJavaScript(
                        "return window.name;",
                        arguments: [:],
                        in: webView,
                        frame: frame,
                        contentWorld: BrowserReplAgentWorld.world
                    )) as? String
                } ?? nil
            }
        }
        var result: [[String: Any]] = []
        for (frame, nameTask) in zip(frames, names) {
            let name = await nameTask.value
            result.append([
                "frameId": frame.frameID,
                "parentFrameId": frame.parentFrameID ?? NSNull(),
                "url": frame.url,
                "name": name ?? frame.name,
                "crossOrigin": frame.crossOrigin,
            ])
        }
        return result
    }

    @MainActor
    private func frame(_ panel: BrowserPanel, _ params: [String: Any]) async throws -> BrowserReplFrame {
        let frameID = params["frameId"] as? String
        if frameID?.isEmpty ?? true {
            // `nil` frame info is the main frame; no frame tree round trip.
            return BrowserReplFrame(
                frameID: "main",
                parentFrameID: nil,
                indexInParent: 0,
                info: nil,
                url: panel.webView.url?.absoluteString ?? "",
                name: "",
                crossOrigin: false
            )
        }
        guard let frame = await BrowserReplFrameTree.frame(frameID, in: panel.webView) else {
            throw Self.error("stale", "Frame \(frameID ?? "main") is detached")
        }
        return frame
    }

    private static let needsAgentSentinel = "__cmuxNeedsAgent__"

    @MainActor
    private func evaluate(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        let world = params["world"] as? String ?? "page"
        let source = params["source"] as? String ?? "() => undefined"
        let args = params["args"] as? [Any] ?? []
        let handles = params["handles"] as? [String] ?? []
        let timeout = (params["timeoutMs"] as? NSNumber)?.intValue ?? 0
        let run: @MainActor () async throws -> Any? = { [self] in
            if world == "agent" {
                return try await self.evaluateInAgentWorld(panel, frame, source: source, args: args, handles: handles)
            }
            return try await self.evaluateInPageWorld(panel, frame, source: source, args: args, handles: handles)
        }
        if timeout > 0 {
            return try await withTimeoutThrowing(milliseconds: timeout, what: "evaluating") { try await run() }
        }
        return try await run()
    }

    /// The function body that runs `source` with handles resolved to elements
    /// (`__els`), returning JSON text, the agent sentinel, or an error envelope.
    private static func evaluationBody(source: String, requiresAgent: Bool, elementsExpression: String) -> String {
        """
        const __agent = globalThis[\(BrowserReplRuntimeBundle.agentGlobalKeyExpression)];
        if (\(requiresAgent ? "true" : "false") && !__agent) return "\(needsAgentSentinel)";
        try {
          const __els = \(elementsExpression);
          const __result = await (\(source))(...__els, ...__args);
          if (__result === undefined) return "null";
          const __json = JSON.stringify(__result);
          return __json === undefined ? "null" : __json;
        } catch (e) {
          return { __cmuxError__: { code: (e && e.code) || "evaluation", message: String(e && e.message !== undefined ? e.message : e), name: (e && e.name) || "Error" } };
        }
        """
    }

    @MainActor
    private func evaluateInAgentWorld(
        _ panel: BrowserPanel,
        _ frame: BrowserReplFrame,
        source: String,
        args: [Any],
        handles: [String]
    ) async throws -> Any? {
        let body = Self.evaluationBody(
            source: source,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        return try await runEvaluation(panel, frame, body: body, world: BrowserReplAgentWorld.world, args: args, handles: handles)
    }

    /// Page-world evaluation. Element handles live in the agent world, so they
    /// cross worlds through the DOM: the page world listens for a one-off
    /// event, the agent world dispatches it on each element, and the page
    /// world reads the targets.
    @MainActor
    private func evaluateInPageWorld(
        _ panel: BrowserPanel,
        _ frame: BrowserReplFrame,
        source: String,
        args: [Any],
        handles: [String]
    ) async throws -> Any? {
        guard !handles.isEmpty else {
            let body = Self.evaluationBody(source: source, requiresAgent: false, elementsExpression: "[]")
            return try await runEvaluation(panel, frame, body: body, world: .page, args: args, handles: [])
        }
        let key = "__cmuxHandleBridge_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let listen = """
        const got = [];
        const listener = (event) => { got.push(event.composedPath()[0]); event.stopImmediatePropagation(); };
        window.addEventListener(__key, listener, true);
        Object.defineProperty(window, __key, { value: { got, listener }, configurable: true, enumerable: false });
        return true;
        """
        do {
            _ = try await frameGate.callAsyncJavaScript(listen, arguments: ["__key": key], in: panel.webView, frame: frame, contentWorld: .page)
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw Self.translate(error)
        }
        let dispatch = Self.evaluationBody(
            source: "(...els) => { for (const el of els) el.dispatchEvent(new CustomEvent(__key, { bubbles: true, composed: true })); return els.length; }",
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        do {
            _ = try await runEvaluation(
                panel,
                frame,
                body: "const __key = \(JSONSerialization.browserReplString(key) ?? "\"\"");\n" + dispatch,
                world: BrowserReplAgentWorld.world,
                args: [],
                handles: handles
            )
        } catch {
            _ = try? await panel.webView.callAsyncJavaScript(
                "const b = window[__key]; if (b) { window.removeEventListener(__key, b.listener, true); delete window[__key]; }",
                arguments: ["__key": key],
                in: frame.info,
                contentWorld: .page
            )
            throw error
        }
        let collect = """
        const __bridge = window[__key];
        delete window[__key];
        if (__bridge) window.removeEventListener(__key, __bridge.listener, true);
        if (!__bridge || __bridge.got.length !== __count) return { __cmuxError__: { code: "stale", message: "Element handle is no longer attached to the document", name: "Error" } };
        """
        let body = collect + "\n" + Self.evaluationBody(source: source, requiresAgent: false, elementsExpression: "__bridge.got")
        return try await runEvaluation(
            panel,
            frame,
            body: body,
            world: .page,
            args: args,
            handles: [],
            extraArguments: ["__key": key, "__count": handles.count]
        )
    }

    @MainActor
    private func runEvaluation(
        _ panel: BrowserPanel,
        _ frame: BrowserReplFrame,
        body: String,
        world: WKContentWorld,
        args: [Any],
        handles: [String],
        extraArguments: [String: Any] = [:]
    ) async throws -> Any? {
        var arguments: [String: Any] = ["__args": args, "__handles": handles]
        arguments.merge(extraArguments) { _, new in new }
        for attempt in 0..<2 {
            let value: Any?
            do {
                // Runs only while the frame shows a document the domain
                // policy allows; a frame looked up from an earlier tree read
                // may have navigated since.
                value = try await frameGate.callAsyncJavaScript(body, arguments: arguments, in: panel.webView, frame: frame, contentWorld: world)
            } catch let error as BrowserReplDriverError {
                throw error
            } catch {
                throw Self.translate(error)
            }
            if let text = value as? String {
                if text == Self.needsAgentSentinel {
                    guard attempt == 0 else { break }
                    try await installAgent(panel, frame)
                    continue
                }
                return BrowserReplRawJSON(text: text)
            }
            if let envelope = (value as? [String: Any])?["__cmuxError__"] as? [String: Any] {
                throw BrowserReplDriverError(
                    code: envelope["code"] as? String ?? "evaluation",
                    message: envelope["message"] as? String ?? "Evaluation failed",
                    errorName: envelope["name"] as? String
                )
            }
            return BrowserReplRawJSON(text: "null")
        }
        throw Self.error("invalid", "The page agent could not be installed in this frame")
    }

    @MainActor
    private func installAgent(_ panel: BrowserPanel, _ frame: BrowserReplFrame) async throws {
        guard let source = bundle.agentInstallSource else {
            throw Self.error("unsupported", "The browser REPL page agent is not bundled")
        }
        attachment(panel).installAgentUserScriptIfNeeded(source: source)
        do {
            _ = try await panel.webView.evaluateJavaScript(source, in: frame.info, contentWorld: BrowserReplAgentWorld.world)
        } catch {
            // Scripts that end in an expression WebKit cannot serialize still
            // installed; the next evaluation tells whether the agent exists.
            let nsError = error as NSError
            if nsError.code != WKError.javaScriptResultTypeIsUnsupported.rawValue {
                throw Self.translate(error)
            }
        }
    }

    private static func translate(_ error: any Error) -> BrowserReplDriverError {
        let nsError = error as NSError
        let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
        if nsError.domain == WKErrorDomain,
           nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue
            || nsError.code == WKError.webContentProcessTerminated.rawValue
            || nsError.code == WKError.webViewInvalidated.rawValue {
            return Self.error("stale", message)
        }
        if message.lowercased().contains("navigat") || message.lowercased().contains("frame") {
            return Self.error("stale", message)
        }
        return BrowserReplDriverError(code: "evaluation", message: message, errorName: "Error")
    }

    @MainActor
    private func ownerBox(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frames = await BrowserReplFrameTree.frames(of: panel.webView)
        guard let frameID = params["frameId"] as? String,
              let child = frames.first(where: { $0.frameID == frameID }) else {
            throw Self.error("stale", "Frame is detached")
        }
        guard let parentID = child.parentFrameID, let parent = frames.first(where: { $0.frameID == parentID }) else {
            return ["x": 0, "y": 0, "width": 0, "height": 0]
        }
        let script = """
        const target = window.frames[__index];
        const find = (root) => {
          for (const el of root.querySelectorAll("iframe, frame")) if (el.contentWindow === target) return el;
          for (const el of root.querySelectorAll("*")) if (el.shadowRoot) { const found = find(el.shadowRoot); if (found) return found; }
          return null;
        };
        const el = target ? find(document) : null;
        if (!el) return null;
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        const px = (v) => parseFloat(v) || 0;
        return {
          x: r.left + el.clientLeft + px(cs.paddingLeft),
          y: r.top + el.clientTop + px(cs.paddingTop),
          width: el.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight),
          height: el.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom),
        };
        """
        do {
            let value = try await frameGate.callAsyncJavaScript(
                script,
                arguments: ["__index": child.indexInParent],
                in: panel.webView,
                frame: parent,
                contentWorld: BrowserReplAgentWorld.world
            )
            return value ?? NSNull()
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    @MainActor
    private func contentFrame(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        guard let element = params["element"] as? String else {
            throw Self.error("invalid", "element is required")
        }
        let body = Self.evaluationBody(
            source: """
            (el) => {
              const w = el && el.contentWindow;
              if (!w) return -1;
              for (let i = 0; i < window.frames.length; i++) if (window.frames[i] === w) return i;
              return -1;
            }
            """,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        let raw = try await runEvaluation(panel, frame, body: body, world: BrowserReplAgentWorld.world, args: [], handles: [element])
        guard let text = (raw as? BrowserReplRawJSON)?.text, let index = Int(text), index >= 0 else { return nil }
        let frames = await BrowserReplFrameTree.frames(of: panel.webView)
        // The main-frame fast path has no tree id; the tree's root is the main frame.
        let parentID = frame.info == nil ? frames.first?.frameID : frame.frameID
        guard let child = frames.first(where: { $0.parentFrameID == parentID && $0.indexInParent == index }) else {
            return nil
        }
        return ["frameId": child.frameID]
    }

    /// The child frames of many `<iframe>` handles of one frame, in one
    /// call: one evaluation maps every handle to its index in
    /// `window.frames`, and one tree read (shared with concurrent callers)
    /// maps indexes to frames. A page of 300 iframes needed 300 calls.
    /// Returns one `{ frameId }` or `null` per handle, in order.
    @MainActor
    private func contentFrames(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        let elements = params["elements"] as? [String] ?? []
        if elements.isEmpty { return [Any]() }
        let body = Self.evaluationBody(
            source: """
            (...els) => {
              const index = new Map();
              for (let i = 0; i < window.frames.length; i++) index.set(window.frames[i], i);
              return els.map((el) => {
                const w = el && el.contentWindow;
                return w && index.has(w) ? index.get(w) : -1;
              });
            }
            """,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => { try { return __agent.element(h); } catch { return null; } })"
        )
        let raw = try await runEvaluation(panel, frame, body: body, world: BrowserReplAgentWorld.world, args: [], handles: elements)
        guard let text = (raw as? BrowserReplRawJSON)?.text,
              let data = text.data(using: .utf8),
              let indexes = (try? JSONSerialization.jsonObject(with: data)) as? [NSNumber] else {
            return elements.map { _ in NSNull() }
        }
        let frames = await BrowserReplFrameTree.frames(of: panel.webView)
        let parentID = frame.info == nil ? frames.first?.frameID : frame.frameID
        var childAt: [Int: String] = [:]
        for child in frames where child.parentFrameID == parentID { childAt[child.indexInParent] = child.frameID }
        return indexes.map { number -> Any in
            guard let id = childAt[number.intValue] else { return NSNull() }
            return ["frameId": id]
        }
    }

    // MARK: - Input

    /// Runs `body` with the panel's web view in a window. A hidden pane's web
    /// view has none, so it borrows the offscreen render host for the call.
    @MainActor
    private func withWindow<T>(_ panel: BrowserPanel, _ body: @escaping @MainActor (CmuxWebView, NSWindow) async throws -> T) async throws -> T {
        guard let webView = panel.webView as? CmuxWebView else {
            throw Self.error("unsupported", "This tab does not accept native input")
        }
        if let window = webView.window {
            return try await body(webView, window)
        }
        return try await panel.withBrowserReplRenderHost {
            guard let window = webView.window else {
                throw Self.error("unsupported", "The tab could not be rendered for input")
            }
            return try await body(webView, window)
        }
    }

    @MainActor
    private func mouse(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let attachment = attachment(panel)
        let type = params["type"] as? String ?? "move"
        let button = BrowserReplMouseButton(rawValue: params["button"] as? String ?? "left") ?? .left
        let clickCount = (params["clickCount"] as? NSNumber)?.intValue ?? 1
        let modifiers = BrowserReplKeyStroke.modifierFlags(named: params["modifiers"] as? [String] ?? [])
        let x = (params["x"] as? NSNumber)?.doubleValue
        let y = (params["y"] as? NSNumber)?.doubleValue
        try await attachment.waitForPointer(sessionID: sessionID)
        if type == "down" { attachment.pointerPressed(sessionID: sessionID) }
        defer { if type == "up" { attachment.pointerReleased(sessionID: sessionID) } }
        if let x, let y { attachment.mousePosition = CGPoint(x: x, y: y) }
        let css = attachment.mousePosition
        try await withWindow(panel) { [self] webView, window in
            let flags = modifiers.union(webView.browserNativeInputDeliveryOwner.activeModifierFlags)
            if type == "wheel" {
                let deltaX = (params["deltaX"] as? NSNumber)?.doubleValue ?? 0
                let deltaY = (params["deltaY"] as? NSNumber)?.doubleValue ?? 0
                guard let event = BrowserReplNativeInput.wheelEvent(
                    webView: webView,
                    window: window,
                    cssPoint: css,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    modifierFlags: flags
                ) else {
                    throw Self.error("invalid", "Could not create a wheel event")
                }
                webView.deliverAutomationMouseEvent(event)
                await BrowserReplNativeInput.roundTrip(webView)
                return
            }
            guard let eventType = attachment.mouseState.eventType(forType: type, button: button) else {
                throw Self.error("invalid", "Unknown mouse event \(type)")
            }
            try await self.deliverMouse(
                eventType,
                button: button,
                at: css,
                clickCount: clickCount,
                flags: flags,
                webView: webView,
                window: window,
                attachment: attachment
            )
        }
        return nil
    }

    /// Delivers one mouse event. A left press arms a drag capture; once
    /// WebKit starts an HTML5 drag, later moves and the release play the drop
    /// side (`draggingUpdated`, `performDragOperation`) instead of mouse
    /// events, the way a real drag session would.
    @MainActor
    private func deliverMouse(
        _ type: NSEvent.EventType,
        button: BrowserReplMouseButton,
        at css: CGPoint,
        clickCount: Int,
        flags: NSEvent.ModifierFlags,
        webView: CmuxWebView,
        window: NSWindow,
        attachment: BrowserReplTabAttachment
    ) async throws {
        func send() throws {
            guard let event = BrowserReplNativeInput.mouseEvent(
                type: type,
                button: button,
                webView: webView,
                window: window,
                cssPoint: css,
                clickCount: clickCount,
                modifierFlags: flags
            ) else {
                throw Self.error("invalid", "Could not create a mouse event")
            }
            webView.deliverAutomationMouseEvent(event)
        }
        let location = BrowserReplNativeInput.windowPoint(webView: webView, cssPoint: css)
        switch type {
        case .leftMouseDown:
            let capture = BrowserAutomationDragCapture()
            webView.automationDragCapture = capture
            attachment.drag = BrowserReplTabAttachment.DragState(capture: capture)
            try send()
            await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
        case .leftMouseDragged:
            if let drop = attachment.drag?.drop {
                drop.draggingLocation = location
                attachment.drag?.operation = webView.draggingUpdated(drop)
                await BrowserReplNativeInput.roundTrip(webView)
                return
            }
            // The drag WebKit may start on this event writes its data to the
            // capture's private pasteboard, never the system's named drag
            // pasteboard; one automated drag's window is open at a time.
            let capture = attachment.drag?.capture
            if let capture {
                guard await capture.openPasteboardWindow() else {
                    if !BrowserReplPasteboardRedirect.shared.install() {
                        throw Self.error("unsupported", "This macOS has no drag pasteboard lookup cmux can redirect, so a drag that would write the system's drag pasteboard is refused; the drag did not move")
                    }
                    if capture.isFinished {
                        throw Self.error("stale", "The drag ended before it moved (the tab's drag state was reset); press the mouse button again")
                    }
                    throw Self.error("timeout", "Another tab's automated drag did not release the drag pasteboard within 5 s; the drag did not move")
                }
            }
            defer { capture?.closePasteboardWindow() }
            try send()
            await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
            await startDropIfDragBegan(webView: webView, window: window, location: location, attachment: attachment)
        case .leftMouseUp:
            if attachment.drag?.drop == nil {
                await startDropIfDragBegan(webView: webView, window: window, location: location, attachment: attachment)
            }
            if let drop = attachment.drag?.drop {
                drop.draggingLocation = location
                let operation = webView.draggingUpdated(drop)
                await BrowserReplNativeInput.roundTrip(webView)
                if !operation.isEmpty, webView.prepareForDragOperation(drop) {
                    _ = webView.performDragOperation(drop)
                    webView.concludeDragOperation(drop)
                } else {
                    webView.draggingExited(drop)
                }
                await BrowserReplNativeInput.roundTrip(webView)
                webView.endAutomationDrag(at: location, operation: operation)
                await BrowserReplNativeInput.roundTrip(webView)
            } else {
                try send()
                await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
            }
            webView.automationDragCapture = nil
            attachment.drag = nil
        default:
            try send()
            await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
        }
    }

    /// WebKit starts a drag asynchronously after the page's `dragstart`; once
    /// it has, enter the web view as the drop destination.
    @MainActor
    private func startDropIfDragBegan(
        webView: CmuxWebView,
        window: NSWindow,
        location: NSPoint,
        attachment: BrowserReplTabAttachment
    ) async {
        guard let state = attachment.drag, state.drop == nil else { return }
        if !state.capture.didBegin {
            await BrowserReplNativeInput.roundTrip(webView)
        }
        guard state.capture.didBegin else { return }
        dragSequence += 1
        let drop = BrowserAutomationDraggingInfo(
            window: window,
            location: location,
            pasteboard: state.capture.pasteboard,
            source: webView,
            sequenceNumber: 1_000_000 + dragSequence
        )
        attachment.drag?.drop = drop
        _ = webView.draggingEntered(drop)
        await BrowserReplNativeInput.roundTrip(webView)
        attachment.drag?.operation = webView.draggingUpdated(drop)
        await BrowserReplNativeInput.roundTrip(webView)
    }

    @MainActor
    private func key(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let type = params["type"] as? String ?? "down"
        let keyName = params["key"] as? String ?? ""
        let code = params["code"] as? String ?? ""
        let text = params["text"] as? String
        let modifiers = params["modifiers"] as? [String] ?? []
        guard let stroke = BrowserReplKeyStroke.resolve(key: keyName, code: code, text: text, modifiers: modifiers) else {
            if type == "down", let text, !text.isEmpty {
                return try await insertText(["targetId": panel.id.uuidString, "text": text])
            }
            if type == "up" { return nil }
            throw Self.error("invalid", "Unknown key: \"\(keyName)\"")
        }
        if type == "down", let command = stroke.editingCommand, Self.clipboardCommandNames[command] != nil {
            try refuseClipboardCommandInUserTab(command, panel: panel)
        }
        try await withWindow(panel) { [self] webView, _ in
            // Tab past the page's last control must not move the user's
            // AppKit focus (WKWebView+AutomationFocusContainment). WebKit asks
            // for that before it answers the round trip below.
            try await webView.withAutomationFocusContainment {
                let result = webView.replayBrowserReplKeyStroke(stroke, keyDown: type == "down")
                guard result == .delivered else {
                    throw Self.error("invalid", "Could not deliver key \"\(keyName)\"")
                }
                self.attachment(panel).heldKeys.record(stroke, keyDown: type == "down")
                if type == "down", let command = stroke.editingCommand {
                    try await self.performEditingCommand(command, panel: panel, webView: webView)
                }
                await BrowserReplNativeInput.roundTrip(webView)
            }
        }
        return nil
    }

    /// Whether the page has a non-empty selection to copy. Focus inside a
    /// frame counts as one, since the frame's selection is not visible here.
    @MainActor
    private static func hasSelection(_ webView: WKWebView) async -> Bool {
        let result = try? await webView.callAsyncJavaScript(
            """
            const el = document.activeElement;
            if (el && (el.tagName === "IFRAME" || el.tagName === "FRAME")) return true;
            if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.selectionStart !== null) {
              return el.selectionEnd > el.selectionStart;
            }
            const selection = getSelection();
            return !!selection && !selection.isCollapsed;
            """,
            arguments: [:],
            in: nil,
            contentWorld: BrowserReplAgentWorld.world
        )
        return (result as? Bool) ?? true
    }

    /// Clipboard shortcuts when WebKit's editing-command SPI is missing: the
    /// selection is read by script and a paste inserts the text, with no
    /// clipboard events.
    @MainActor
    private func performClipboardCommandWithoutWebKit(
        _ command: String,
        attachment: BrowserReplTabAttachment,
        webView: CmuxWebView
    ) async throws {
        switch command {
        case "copy:", "cut:":
            let selection = try? await webView.callAsyncJavaScript(
                """
                const el = document.activeElement;
                if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.selectionStart !== null) {
                  return el.value.slice(el.selectionStart, el.selectionEnd);
                }
                return String(getSelection() || "");
                """,
                arguments: [:],
                in: nil,
                contentWorld: BrowserReplAgentWorld.world
            ) as? String
            let text = selection ?? ""
            attachment.clipboardItems = [["type": "text/plain", "base64": Data(text.utf8).base64EncodedString()]]
            if command == "cut:", !text.isEmpty {
                NSApp.sendAction(NSSelectorFromString("delete:"), to: webView, from: nil)
            }
        default:
            let text = attachment.clipboardItems
                .first { ($0["type"] as? String) == "text/plain" }
                .flatMap { ($0["base64"] as? String).flatMap { Data(base64Encoded: $0) } }
                .map { String(decoding: $0, as: UTF8.self) }
            if let text, !text.isEmpty {
                try? await BrowserReplNativeInput.insertText(text, into: webView)
            }
        }
    }

    /// WebKit's command name for each Cocoa clipboard action.
    private static let clipboardCommandNames = ["copy:": "Copy", "cut:": "Cut", "paste:": "Paste"]

    /// Meta+C, Meta+X and Meta+V run only in tabs a session created. WebKit
    /// runs them against the general pasteboard's name, and a page that
    /// keeps one running past its timeout is contained by ending the tab's
    /// web content process, which cmux never does to a user's tab; so the
    /// shortcut is refused there before any key reaches the page.
    @MainActor
    private func refuseClipboardCommandInUserTab(_ command: String, panel: BrowserPanel) throws {
        guard !attachment(panel).appliesSessionPolicies else { return }
        let name = Self.clipboardCommandNames[command] ?? command
        throw Self.error(
            "unsupported",
            "\(name) is refused in a user's tab (one no attached session opened): cmux ends the web content process of a tab whose page keeps a Copy, Cut or Paste running past its timeout, and it never does that to a user's tab. Use page.clipboard here, or open the page with tabs.open()"
        )
    }

    /// The tabs `creator` created, by panel id.
    @MainActor
    private func tabsCreated(by creator: String) -> Set<UUID> {
        Set(allBrowserPanels().compactMap { entry in
            BrowserReplTabAttachments.shared.attachment(for: entry.panel.id)?.creatorSessionID == creator ? entry.panel.id : nil
        })
    }

    /// Whether ending `webView`'s web content process ends nothing of the
    /// user's: every other web view in that process is a browser tab in
    /// `sessionTabs` (the tabs the commanding session created when the
    /// command started, which stay its tabs for the command even when it
    /// detaches meanwhile) or one that session created since. A floating
    /// popup window is the user's. `webView` itself is the commanded tab's,
    /// also after that tab closed. A process that is already gone may be
    /// "ended".
    @MainActor
    private func webContentEndsOnlySessionTabs(_ webView: WKWebView, creator: String, sessionTabs: Set<UUID>) -> Bool {
        guard let pid = CmuxWebContentProcessIdentifier.pid(for: webView) else { return true }
        for (other, _) in allBrowserPanels() {
            if other.webView !== webView, CmuxWebContentProcessIdentifier.pid(for: other.webView) == pid,
               !sessionTabs.contains(other.id),
               BrowserReplTabAttachments.shared.attachment(for: other.id)?.creatorSessionID != creator {
                return false
            }
            for popup in other.floatingPopupWebViews where popup !== webView {
                if CmuxWebContentProcessIdentifier.pid(for: popup) == pid { return false }
            }
        }
        return true
    }

    /// Runs the Cocoa editing action behind a Command shortcut. Clipboard
    /// actions use the tab's virtual clipboard, not the system pasteboard:
    /// WebKit's own Copy, Cut and Paste run against a private pasteboard that
    /// holds the tab's clipboard, so the page gets trusted `copy`, `cut` and
    /// `paste` events with `clipboardData`, as a person's shortcut gives it.
    /// The private pasteboard stands in for at most 5 s; a page that keeps
    /// the command running longer has its web content process ended then
    /// (`BrowserReplPasteboardRedirect`), so nothing it does later reaches
    /// the system clipboard. Only tabs a session created run these.
    @MainActor
    private func performEditingCommand(_ command: String, panel: BrowserPanel, webView: CmuxWebView) async throws {
        let attachment = attachment(panel)
        switch command {
        case "copy:", "cut:", "paste:":
            try refuseClipboardCommandInUserTab(command, panel: panel)
            let isPaste = command == "paste:"
            // WebKit beeps on Copy or Cut with nothing selected; that case
            // keeps the script path, which empties the tab's clipboard.
            if !isPaste, await !Self.hasSelection(webView) {
                try await performClipboardCommandWithoutWebKit(command, attachment: attachment, webView: webView)
                return
            }
            // The tab's creator and its tabs now: a session that detaches,
            // or a tab that closes, during the command leaves the page no
            // way to keep its process from being ended.
            guard panel.webView === webView, let creator = attachment.creatorSessionID else {
                try await performClipboardCommandWithoutWebKit(command, attachment: attachment, webView: webView)
                return
            }
            let sessionTabs = tabsCreated(by: creator)
            let pasteboard = NSPasteboard.withUniqueName()
            if isPaste {
                BrowserReplClipboardItems.write(attachment.clipboardItems, to: pasteboard)
            } else {
                pasteboard.clearContents()
            }
            let name = Self.clipboardCommandNames[command] ?? command
            // Until WebKit reports the command done, a JavaScript dialog from
            // the page is answered at once instead of held for the session,
            // so it cannot keep the command open.
            attachment.clipboardCommandsInFlight.append(name.lowercased())
            let outcome = await BrowserReplPasteboardRedirect.shared.perform(
                name,
                in: webView,
                pasteboard: pasteboard,
                tab: panel.id.uuidString,
                mayEndWebContent: { [weak self] in
                    guard let self else { return true }
                    return self.webContentEndsOnlySessionTabs(webView, creator: creator, sessionTabs: sessionTabs)
                }
            ) { [weak attachment] in
                attachment?.clipboardCommandFinished(name.lowercased())
            }
            // The tab's clipboard takes only what this command wrote: the
            // pasteboard was reachable only during the command's own window,
            // which no other REPL command shares. It is emptied and released
            // here, except after `timedOutStillRunning`, when the redirect
            // releases it once WebKit finishes or its grace ends.
            defer {
                if outcome != .timedOutStillRunning {
                    pasteboard.clearContents()
                    pasteboard.releaseGlobally()
                }
            }
            switch outcome {
            case .completed:
                if !isPaste {
                    let items = BrowserReplClipboardItems.read(pasteboard)
                    // Copying nothing leaves an empty clipboard, as before.
                    attachment.clipboardItems = items.isEmpty
                        ? [["type": "text/plain", "base64": ""]]
                        : items
                }
            case .timedOut:
                throw Self.error(
                    "timeout",
                    "\(name) did not finish within 5 s, so cmux ended the tab's web content process: nothing the page does later reaches the system clipboard. The tab's clipboard is unchanged; call page.reload() or page.goto() to load the page again"
                )
            case .timedOutStillRunning:
                throw Self.error(
                    "timeout",
                    "\(name) did not finish within 5 s and the tab's clipboard is unchanged. The tab's web content process also runs a tab or popup window no session created, so cmux gives the page up to 5 s more: until it finishes, WebKit's copies and pastes in every browser tab use a private pasteboard, never the system clipboard, and Copy, Cut and Paste wait for it. Then cmux ends that process, and the pages in it crash (page.reload() loads them again)"
                )
            case .busy(let tab):
                throw Self.error(
                    "timeout",
                    "\(name) did not start within 5 s: a Copy, Cut or Paste in tab \(tab) has not finished. One runs at a time across all tabs, since WebKit's pasteboard requests do not say which tab they serve"
                )
            case .interfered:
                throw Self.error(
                    "stale",
                    "\(name) finished, but another web view copied, pasted or read the clipboard during it (WebKit's pasteboard requests do not say which web view they serve), so the tab's clipboard is unchanged\(isPaste ? " and the page may have pasted nothing" : ""). Try again"
                )
            case .unavailable:
                try await performClipboardCommandWithoutWebKit(command, attachment: attachment, webView: webView)
            }
        case "bold", "italic", "underline":
            // Chrome's editor formats the selection of an editable element on
            // Command+B/I/U; the page sees its usual beforeinput and input.
            _ = try? await webView.callAsyncJavaScript(
                """
                const el = document.activeElement;
                if (!(document.designMode === "on" || (el && el.isContentEditable))) return false;
                return document.execCommand(command);
                """,
                arguments: ["command": command],
                in: nil,
                contentWorld: .page
            )
        default:
            NSApp.sendAction(NSSelectorFromString(command), to: webView, from: nil)
        }
    }

    @MainActor
    private func insertText(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let text = params["text"] as? String ?? ""
        guard !text.isEmpty else { return nil }
        // A secret from the native session: typed only when the focused
        // frame's own origin is on the secret's domains, checked on every
        // call right before the text is committed (BrowserReplTextCommitTarget.commit),
        // after the wait for WebKit's editor state, during which the page
        // can move focus. What remains is the cross-process gap between the
        // check's last reply and the insert reaching the web process.
        let sessionID = self.sessionID
        let checkTarget: @MainActor @Sendable () async throws -> Void = {
            guard let name = params["secretName"] as? String else { return }
            let frames = await BrowserReplFrameTree.frames(of: panel.webView)
            let rawDomains = params["secretDomains"] as? [[String: Any]] ?? []
            try await BrowserReplSecretGuard.checkSecretTarget(
                name: name,
                domains: rawDomains,
                webView: panel.webView,
                frames: frames
            )
            // Recorded once the domain check passes and before typing, on
            // the same main-actor turn as the commit: other sessions that
            // read the tab do not hold the secret, so the tab keeps it
            // masked for them, also when typing fails partway and part of
            // the value is already in the page. A refused value is never
            // recorded, so it never becomes a mask other sessions see.
            BrowserReplTabAttachments.shared.typedSecrets.record(
                tab: panel.id.uuidString,
                name: name,
                value: text,
                domains: rawDomains.compactMap(BrowserReplDomainPattern.from(json:)),
                typist: sessionID
            )
        }
        try await withWindow(panel) { webView, _ in
            try await BrowserReplNativeInput.insertText(text, into: webView, checkTarget: checkTarget)
            await BrowserReplNativeInput.roundTrip(webView)
        }
        return nil
    }

    /// HTML5 drag and drop: presses at the first point, moves through the
    /// path in small steps and releases at the last, through the same drag
    /// state machine as individual `input.mouse` calls.
    @MainActor
    private func drag(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let attachment = attachment(panel)
        let points: [CGPoint] = (params["path"] as? [[String: Any]] ?? []).compactMap { point in
            guard let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            throw Self.error("invalid", "input.drag needs at least two points")
        }
        let modifiers = BrowserReplKeyStroke.modifierFlags(named: params["modifiers"] as? [String] ?? [])
        var trail: [CGPoint] = []
        for (previous, next) in zip(points, points.dropFirst()) {
            for step in 1...5 {
                let t = CGFloat(step) / 5
                trail.append(CGPoint(x: previous.x + (next.x - previous.x) * t, y: previous.y + (next.y - previous.y) * t))
            }
        }
        // The drag holds the tab's pointer like a press does (input.mouse), so
        // another session's mouse input never interleaves with it.
        try await attachment.performPointerGesture(sessionID: sessionID) {
            try await withWindow(panel) { [self] webView, window in
                let flags = modifiers.union(webView.browserNativeInputDeliveryOwner.activeModifierFlags)
                attachment.mouseState.reset()
                _ = attachment.mouseState.eventType(forType: "move", button: .left)
                try await self.deliverMouse(.mouseMoved, button: .left, at: first, clickCount: 0, flags: flags, webView: webView, window: window, attachment: attachment)
                _ = attachment.mouseState.eventType(forType: "down", button: .left)
                try await self.deliverMouse(.leftMouseDown, button: .left, at: first, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
                for point in trail {
                    try await self.deliverMouse(.leftMouseDragged, button: .left, at: point, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
                }
                _ = attachment.mouseState.eventType(forType: "up", button: .left)
                try await self.deliverMouse(.leftMouseUp, button: .left, at: last, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
            }
            attachment.mousePosition = last
        }
        return nil
    }

    /// The points an `input.drag` presses, moves through and releases at
    /// (`drag`): the first point, then five steps along each segment.
    private static func dragTrail(_ params: [String: Any]) -> [CGPoint] {
        let points: [CGPoint] = (params["path"] as? [[String: Any]] ?? []).compactMap { point in
            guard let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let first = points.first else { return [] }
        var trail = [first]
        for (previous, next) in zip(points, points.dropFirst()) {
            for step in 1...5 {
                let t = CGFloat(step) / 5
                trail.append(CGPoint(x: previous.x + (next.x - previous.x) * t, y: previous.y + (next.y - previous.y) * t))
            }
        }
        return trail
    }

    @MainActor
    private func setFiles(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        guard let element = params["element"] as? String else {
            throw Self.error("invalid", "element is required")
        }
        let files = params["files"] as? [[String: Any]] ?? []
        let body = Self.evaluationBody(
            source: """
            (el, files) => {
              if (!(el instanceof HTMLInputElement) || el.type !== "file") throw new Error("Node is not an HTMLInputElement of type file");
              const transfer = new DataTransfer();
              for (const f of files) {
                const binary = atob(f.base64 || "");
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                transfer.items.add(new File([bytes], f.name, { type: f.mimeType || "" }));
              }
              el.files = transfer.files;
              el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
              el.dispatchEvent(new Event("change", { bubbles: true }));
              return el.files.length;
            }
            """,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        _ = try await runEvaluation(panel, frame, body: body, world: BrowserReplAgentWorld.world, args: [files], handles: [element])
        return nil
    }

    @MainActor
    private func respondToFileChooser(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
        guard let id = params["chooserId"] as? String else {
            throw Self.error("invalid", "chooserId is required")
        }
        var urls: [URL]?
        if params["cancel"] as? Bool != true {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-repl-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileChooserDirectories.append(directory)
            urls = try (params["files"] as? [[String: Any]] ?? []).map { file in
                let name = ((file["name"] as? String) ?? "file").replacingOccurrences(of: "/", with: "_")
                let url = directory.appendingPathComponent(name.isEmpty ? "file" : name)
                try (Data(base64Encoded: file["base64"] as? String ?? "") ?? Data()).write(to: url)
                return url
            }
        }
        // Only the session the chooser was routed to may answer it.
        guard attachment(panel).respondToFileChooser(id: id, sessionID: sessionID, files: urls) else {
            throw Self.error("not_found", "File chooser \(id) is gone")
        }
        return nil
    }

    @MainActor
    private func respondToDialog(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
        guard let id = params["dialogId"] as? String else {
            throw Self.error("invalid", "dialogId is required")
        }
        let accept = params["accept"] as? Bool ?? false
        // Only the session the dialog was routed to may answer it.
        guard attachment(panel).respondToDialog(id: id, sessionID: sessionID, accept: accept, promptText: params["promptText"] as? String) else {
            throw Self.error("not_found", "Dialog \(id) is gone")
        }
        return nil
    }

    @MainActor
    private func downloadPath(_ params: [String: Any]) async throws -> Any? {
        guard let id = params["downloadId"] as? String else {
            throw Self.error("invalid", "downloadId is required")
        }
        // Completion is state in the ledger: a download that finished before
        // or while this call gets ready to wait is returned, never missed.
        let ledger = downloads
        let outcome = await withTimeout(milliseconds: 120_000) { await ledger.wait(for: id) } ?? nil
        guard let path = outcome?.path else {
            throw Self.error("not_found", "Download \(id) did not complete\(outcome?.error.map { ": \($0)" } ?? "")")
        }
        return ["path": path]
    }

    @MainActor
    private func closeOpenedTabs() {
        let opened = openedTargetIDs
        openedTargetIDs.removeAll()
        guard let workspace = try? workspace() else { return }
        for id in opened where workspace.panels[id] is BrowserPanel {
            BrowserReplTabAttachments.shared.panelDidClose(id)
            _ = workspace.closePanel(id, force: true)
        }
    }

    @MainActor
    private func releaseDownloadWaiters() {
        downloads.releaseWaiters()
    }

    // MARK: - Capture

    @MainActor
    private func screenshot(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        let format = params["format"] as? String ?? "png"
        let quality = (params["quality"] as? NSNumber)?.doubleValue
        let fullPage = params["fullPage"] as? Bool ?? false
        let clip = params["clip"] as? [String: Any]
        let masks = typedSecretMasks(params)
        let policy = currentPolicy
        let frameGate = self.frameGate
        let image: CGImage = try await withWindow(panel) { webView, _ in
            try await Self.withSecretMasks(masks, policy: policy, blockedChildFrames: .handToCapture, webView: webView) { blockedChildFrames in
                // Frames the domain policy blocks (an ad or tracker under
                // allowedDomains) are blanked, not the whole capture refused:
                // those of the tree, and those whose document the mask found
                // blocked (a frame that navigated after the tree was read).
                try await frameGate.coverBlockedFrames(
                    in: webView,
                    frames: { await BrowserReplFrameTree.frames(of: webView) },
                    blockedChildFrames: blockedChildFrames
                ) {
                    try await BrowserReplCapture.snapshotWithRegion(webView: webView, clip: clip, fullPage: fullPage)
                }
            }
        }
        let data = try BrowserReplCapture.encode(image, format: format, quality: quality)
        return ["base64": data.base64EncodedString(), "width": image.width, "height": image.height]
    }

    @MainActor
    private func pdf(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        let masks = typedSecretMasks(params)
        let policy = currentPolicy
        let data: Data = try await withWindow(panel) { [self] webView, _ in
            // A PDF cannot blank a frame: any frame whose marked document
            // the policy blocks refuses it, also one that navigated after
            // checkFramePolicy read the tree.
            try await Self.withSecretMasks(masks, policy: policy, blockedChildFrames: .refuse, webView: webView) { _ in
                try await self.printPDF(webView: webView, params: params)
            }
        }
        return ["base64": data.base64EncodedString()]
    }

    /// Runs `capture` with registered secrets masked in frames on their
    /// domains, bound to the documents the frames show, and refuses it when
    /// the main frame, or with `.refuse` any frame, shows a page the policy
    /// blocks; with `.handToCapture` `capture` gets the blocked child frames
    /// to blank (BrowserReplCaptureMask).
    @MainActor
    private static func withSecretMasks<T>(
        _ masks: [[String: Any]],
        policy: BrowserReplDomainPolicy,
        blockedChildFrames: BrowserReplCaptureMask.BlockedChildFrames,
        webView: WKWebView,
        _ capture: (_ blockedChildFrames: [String: String]) async throws -> T
    ) async throws -> T {
        try await BrowserReplCaptureMask(secretMasks: masks, policy: policy, blockedChildFrames: blockedChildFrames).run(
            in: webView,
            frames: { await BrowserReplFrameTree.frames(of: webView).map(\.info) },
            capture
        )
    }

    @MainActor
    private func printPDF(webView: WKWebView, params: [String: Any]) async throws -> Data {
        // withWindow only lays a hidden tab out at its viewport size; the
        // print session runs for a private offscreen window, never this
        // one. If printing never reports back, fall back to WebKit's
        // single-page PDF.
        do {
            return try await withTimeoutThrowing(milliseconds: 20_000, what: "printing") {
                try await BrowserReplCapture.printPDF(webView: webView, options: params)
            }
        } catch {
            return try await webView.pdf(configuration: WKPDFConfiguration())
        }
    }

    // MARK: - Browser state

    @MainActor
    private func cookieStore(_ params: [String: Any]) throws -> WKHTTPCookieStore {
        try cookieTab(params).store.httpCookieStore
    }

    /// The data store cookie calls use, and the tab it belongs to: the
    /// target tab's (a tab this session can reach, else the call fails),
    /// else the store the session's next tab opens in (its
    /// `session.configure({ proxy })` store), else the active tab's, else
    /// the default profile's. The runtime names the tab on every call a
    /// page makes, so a private or proxied tab never reads or writes
    /// another tab's store.
    @MainActor
    private func cookieTab(_ params: [String: Any]) throws -> (store: WKWebsiteDataStore, panel: BrowserPanel?) {
        if params["targetId"] != nil {
            let panel = try panel(params)
            return (panel.webView.configuration.websiteDataStore, panel)
        }
        if let proxyDataStore {
            return (proxyDataStore, nil)
        }
        let panels = try browserPanels()
        let preferred = activeTargetID.flatMap(UUID.init(uuidString:)).flatMap { id in panels.first { $0.id == id } }
            ?? panels.first
        if let preferred {
            return (preferred.webView.configuration.websiteDataStore, preferred)
        }
        let store = BrowserProfileStore.shared
            .websiteDataStore(for: BrowserPanel.resolvedProfileID(requested: nil))
        return (store, nil)
    }


    /// Refuses a cookie call on a URL the domain policy blocks.
    @MainActor
    private func checkCookieURLs(_ urls: [String], method: String) throws {
        let policy = currentPolicy
        for url in urls {
            if let reason = policy.blockReason(url) {
                throw Self.error("blocked", "\(method): \(url) is blocked: \(reason)")
            }
        }
    }

    /// Cookies of sites the domain policy blocks are never listed, set or
    /// cleared (BrowserReplDomainPolicy.cookieBlockReason).
    @MainActor
    private func cookies(_ params: [String: Any]) async throws -> [[String: Any]] {
        let rawURLs = params["urls"] as? [String] ?? []
        try checkCookieURLs(rawURLs, method: "cookies.get")
        let policy = currentPolicy
        let store = try cookieStore(params)
        let all = await store.allCookies().filter { policy.cookieBlockReason(domain: $0.domain) == nil }
        let urls = rawURLs.compactMap(URL.init(string:))
        let filtered = urls.isEmpty ? all : all.filter { cookie in
            urls.contains { BrowserReplCapture.cookie(cookie, matches: $0) }
        }
        return filtered.map(\.browserReplJSON)
    }

    @MainActor
    private func setCookies(_ params: [String: Any]) async throws -> Any? {
        let policy = currentPolicy
        var cookies: [HTTPCookie] = []
        for json in params["cookies"] as? [[String: Any]] ?? [] {
            guard let cookie = HTTPCookie.browserRepl(from: json) else {
                throw Self.error("invalid", "Invalid cookie \(json["name"] as? String ?? "")")
            }
            if let url = json["url"] as? String { try checkCookieURLs([url], method: "cookies.set") }
            // The domain as the caller wrote it: a leading dot (or none) decides
            // whether the cookie reaches subdomains.
            let written = json["domain"] as? String ?? cookie.domain
            if let reason = policy.cookieSetBlockReason(domain: written) {
                throw Self.error("blocked", "cookies.set: a cookie on \(written) is blocked: \(reason)")
            }
            cookies.append(cookie)
        }
        let store = try cookieStore(params)
        for cookie in cookies { await store.setCookie(cookie) }
        return nil
    }

    /// Deletes the cookies `BrowserReplCookieClearScope` selects: those of
    /// the site of the tab whose store this is (decided here, not by the
    /// caller), narrowed by `name`, `domain` and `path`. `all` is refused on
    /// the user's profile; a private or proxy store may be cleared whole.
    /// Cookies of sites the domain policy blocks are left alone.
    @MainActor
    private func clearCookies(_ params: [String: Any]) async throws -> Any? {
        let policy = currentPolicy
        if let domain = params["domain"] as? String, !domain.isEmpty,
           let reason = policy.cookieBlockReason(domain: domain) {
            throw Self.error("blocked", "cookies.clear: \(domain) is blocked: \(reason)")
        }
        let (dataStore, panel) = try cookieTab(params)
        let scope: BrowserReplCookieClearScope
        do {
            scope = try BrowserReplCookieClearScope(
                params: params,
                tabURL: panel?.webView.url,
                storeIsPersistent: dataStore.isPersistent,
                publicSuffixes: .system
            )
        } catch let refusal as BrowserReplCookieClearScope.Refusal {
            throw Self.error("invalid", refusal.message)
        }
        let store = dataStore.httpCookieStore
        for cookie in await store.allCookies()
        where scope.includes(name: cookie.name, domain: cookie.domain, path: cookie.path)
            && policy.cookieBlockReason(domain: cookie.domain) == nil {
            await store.deleteCookie(cookie)
        }
        return nil
    }

    @MainActor
    private func readClipboard(_ params: [String: Any]) throws -> [String: Any] {
        ["items": attachment(try panel(params)).clipboardItems]
    }

    @MainActor
    private func writeClipboard(_ params: [String: Any]) throws -> Any? {
        attachment(try panel(params)).clipboardItems = params["items"] as? [[String: Any]] ?? []
        return nil
    }

    // MARK: - Timeouts

    /// Runs `body`, returning `nil` if it has not finished after `milliseconds`.
    /// The body keeps running in the background when the deadline wins.
    @MainActor
    private func withTimeout<T: Sendable>(
        milliseconds: Int,
        _ body: @escaping @MainActor () async -> T
    ) async -> T? {
        try? await withTimeoutThrowing(milliseconds: milliseconds, what: "") { await body() }
    }

    @MainActor
    @discardableResult
    private func withTimeoutThrowing<T>(
        milliseconds: Int,
        what: String,
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let race = BrowserReplRace<T>()
        let work = Task { @MainActor in
            do {
                race.finish(.success(try await body()))
            } catch {
                race.finish(.failure(error))
            }
        }
        let sleeper = self.sleeper
        let deadline = Task { @MainActor in
            do {
                try await sleeper.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            race.finish(.failure(Self.error("timeout", "Timeout \(milliseconds)ms exceeded\(what.isEmpty ? "" : " while \(what)")")))
        }
        defer {
            deadline.cancel()
        }
        let result = try await race.value()
        if race.timedOut { work.cancel() }
        return result
    }
}

/// First-result-wins completion for `withTimeoutThrowing`.
@MainActor
private final class BrowserReplRace<T> {
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?
    private(set) var timedOut = false

    func finish(_ value: Result<T, any Error>) {
        guard result == nil else { return }
        if case .failure(let error as BrowserReplDriverError) = value, error.code == "timeout" {
            timedOut = true
        }
        result = value
        if let continuation {
            self.continuation = nil
            continuation.resume(with: value)
        }
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
}
