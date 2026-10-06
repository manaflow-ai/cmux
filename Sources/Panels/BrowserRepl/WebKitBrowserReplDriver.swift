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
    /// A policy and the board generation it was published as.
    private struct PolicyUpdate: Sendable {
        let policy: BrowserReplDomainPolicy
        let generation: Int
    }
    /// Applies policies' content rules one at a time, the newest only: a
    /// policy superseded while another compiles is never compiled. Calls
    /// wait for it.
    private lazy var policyRunner = BrowserReplLatestValueRunner<PolicyUpdate> { [weak self] update in
        await self?.applyDomainPolicy(update.policy, generation: update.generation)
    }
    /// Set while WebKit refuses the latest policy's content rules: every
    /// call fails with it until a policy that compiles replaces it.
    @MainActor private var policyFailure: BrowserReplDriverError?
    /// Applies the domain policy to each frame a call reads or acts on, by
    /// WebKit's record of the frame and its document read in the driver's
    /// own content world. In a tab the session did not create it also
    /// refuses every frame that shows a local document outside the
    /// session's directories, whatever the policy.
    @MainActor private lazy var frameGate: BrowserReplFrameGate = {
        let gate = BrowserReplFrameGate(world: BrowserReplDriverWorld.world)
        gate.scope = { [weak self] webView in self?.frameGateScope(webView) }
        // One shared tree read for the gate's reach check (BrowserReplFrameTree).
        gate.frameTree = { await BrowserReplFrameTree.frames(of: $0) }
        return gate
    }()
    /// Ties `<iframe>` elements to their child frames' ids.
    @MainActor private lazy var frameBinding = BrowserReplFrameBinding(world: BrowserReplDriverWorld.world)
    /// This session's own agent world, in every tab it drives: its page
    /// agent, refs and handles, and its `frame.evaluate` with
    /// `world: "agent"`. No other session's code runs there, and none of
    /// this session's code runs in the driver's guard worlds.
    @MainActor private lazy var sessionWorld = BrowserReplSessionWorld()

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

    func typedSecretRedaction() -> BrowserReplSecretStore? {
        BrowserReplTabAttachments.typedSecrets.redaction(forReader: sessionID)
    }

    /// The session's check that a secret a call carries is still the one it
    /// holds (``BrowserReplDriver/setSecretCheck(_:)``); `nil` refuses
    /// every secret.
    private var secretCheck: (@Sendable (String, Int) -> Bool)?

    func setSecretCheck(_ isCurrent: @escaping @Sendable (_ name: String, _ revision: Int) -> Bool) {
        lock.withLock { secretCheck = isCurrent }
    }

    /// Publishes `policy` to the navigation checks before it returns
    /// (``BrowserReplPolicyBoard``): the next navigation or popup of the
    /// session's tabs is judged by it. WebKit compiles its content rules
    /// afterwards; until they are on the tabs, the session's calls wait
    /// (`dispatchAttached`) and its tabs' navigations wait
    /// (`BrowserReplNavigationGuard.hold`). Only the newest policy waiting
    /// is compiled (`policyRunner`), so a burst of updates costs WebKit at
    /// most the compilation in progress and the last.
    func setDomainPolicy(_ policy: BrowserReplDomainPolicy) {
        lock.withLock {
            domainPolicy = policy
            let generation = BrowserReplPolicyBoard.shared.publish(policy, sessionID: sessionID)
            policyRunner.submit(PolicyUpdate(policy: policy, generation: generation))
        }
        failClosedUntilRulesInstall()
    }

    /// Puts the session's tabs under the fail-closed list on the main
    /// actor's next turn, ahead of the compile the policy runner starts:
    /// their live pages load nothing under the previous rules until the
    /// new list is on them (``BrowserReplTabAttachments/rulesInForce(forSession:)``).
    private func failClosedUntilRulesInstall() {
        let sessionID = sessionID
        Task { @MainActor in BrowserReplTabAttachments.shared.applyRules(forSession: sessionID) }
    }

    /// Puts the policy's content rules on the tabs the session created, then
    /// releases the navigations that waited for them.
    @MainActor
    private func applyDomainPolicy(_ policy: BrowserReplDomainPolicy, generation: Int) async {
        // A policy that lands after the session ended must not put state
        // back for it (detach() waits for this task, then tears down).
        guard !lock.withLock({ isDetached }) else { return }
        frameGate.policy = policy
        var options = contextOptions ?? BrowserReplContextOptions()
        let roots = currentFileRoots
        do {
            // The local-file rules first: a policy's allow list blocks every
            // load it does not name, files inside the roots included.
            let rules = BrowserReplFileSandbox.contentRules(roots: roots) + policy.contentRules
            options.ruleList = try await compileRuleList(rules)
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
            BrowserReplPolicyBoard.shared.rulesFailed(sessionID: sessionID, generation: generation, reason: reason)
            // The tabs stay under the fail-closed list until a policy compiles.
            BrowserReplTabAttachments.shared.applyRules(forSession: sessionID)
            return
        }
        contextOptions = options
        // The list goes on the tabs only when it is the latest policy's;
        // a newer one keeps them under the fail-closed list.
        BrowserReplTabAttachments.shared.setContext(options, forSession: sessionID, rulesGeneration: generation)
        BrowserReplPolicyBoard.shared.rulesInstalled(sessionID: sessionID, generation: generation)
        let previous = tabsAuthority ?? BrowserReplDocumentAuthority(sessionID: sessionID)
        let now = BrowserReplDocumentAuthority(sessionID: sessionID, policy: policy, fileRoots: roots)
        tabsAuthority = now
        // The session's calls wait for this task (policyRunner), so none
        // reaches a page that loaded under the looser authority.
        await replacePages(after: previous, now)
    }

    /// The policy and directories whose content rules were last put on the
    /// session's tabs.
    @MainActor private var tabsAuthority: BrowserReplDocumentAuthority?

    /// Content rules judge a connection or a frame only when it opens: a
    /// page that loaded under a looser policy keeps a WebSocket to a host
    /// the new one blocks, and one of a local file's origin keeps reading
    /// files of a directory the session left. So after new rules are on
    /// the session's tabs, each live page of a tab the session created
    /// that the authority no longer allows as it is
    /// (``BrowserReplDocumentAuthority/pageReplacement(after:in:)``) is
    /// loaded again or becomes `about:blank` (its old document and every
    /// connection it held end), and the tab's sessions get `tab.replaced`
    /// with the reason. A tab whose page cannot be replaced within 10 s is
    /// closed.
    @MainActor
    private func replacePages(after previous: BrowserReplDocumentAuthority, _ now: BrowserReplDocumentAuthority) async {
        for attachment in BrowserReplTabAttachments.shared.attachments(forSession: sessionID) {
            guard let panel = attachment.panel, panel.webView.url != nil else { continue }
            let reason: String
            var replaced = false
            switch now.pageReplacement(after: previous, in: tabFacts(panel, workspaceID: nil)) {
            case .keep:
                continue
            case .reload(let why):
                reason = why
                if let (ticket, _) = panel.beginAutomationReloadFromCLI() {
                    replaced = await settle(ticket, in: panel)
                }
            case .blank(let why):
                reason = why
            }
            if !replaced, let blank = URL(string: "about:blank") {
                replaced = await settle(panel.beginAutomationNavigation(to: blank, recordTypedNavigation: false), in: panel)
            }
            guard replaced else {
                if let workspace = Self.browserPanelEntries().first(where: { $0.panel.id == panel.id })?.workspace {
                    _ = workspace.closePanel(panel.id, force: true)
                }
                continue
            }
            attachment.emit(.tabReplaced, ["reason": reason])
        }
    }

    /// Whether navigation `ticket` of `panel` committed within 10 s; one
    /// that did not is stopped.
    @MainActor
    private func settle(_ ticket: BrowserAutomationNavigationTicket, in panel: BrowserPanel) async -> Bool {
        let outcome = try? await withTimeoutThrowing(milliseconds: 10_000, what: "replacing the page") {
            await panel.finishAutomationNavigation(ticket)
        }
        if outcome == .committed { return true }
        panel.automationNavigationCoordinator.stop(ticket, loading: panel.webView)
        return false
    }

    private var currentPolicy: BrowserReplDomainPolicy { lock.withLock { domainPolicy } }

    /// The session's working and temporary directories (canonical), the
    /// only ones its tabs may show local files from. Only the native
    /// session sets them, through `setFileRoots`.
    /// Each with the identity of its directory when the session named it,
    /// which a file navigation requires it still has.
    private var fileRoots: [BrowserReplFileRoot] = []

    /// Publishes the directories to the navigation checks before it returns
    /// (``BrowserReplPolicyBoard``), and puts content rules that load local
    /// files from them only on the session's tabs, as a policy change does.
    func setFileRoots(_ roots: [String]) {
        let pinned = roots.map(BrowserReplFileRoot.init(path:))
        lock.withLock {
            fileRoots = pinned
            BrowserReplPolicyBoard.shared.setFileRoots(roots, sessionID: sessionID)
            let generation = BrowserReplPolicyBoard.shared.publish(domainPolicy, sessionID: sessionID)
            policyRunner.submit(PolicyUpdate(policy: domainPolicy, generation: generation))
        }
        failClosedUntilRulesInstall()
    }

    private var currentFileRoots: [String] { lock.withLock { fileRoots.map(\.path) } }

    /// The session's own input: a dialog, file chooser or window the page
    /// opens while it handles one goes to the session. A page-world
    /// `frame.evaluate` holds that window for at most a second, and
    /// navigations until they commit (`navigate`, `history`, `reload`), so
    /// the user's own dialogs in the tab stay the user's.
    private static func isActionOnPage(_ method: String) -> Bool {
        method.hasPrefix("input.")
    }

    /// This session's ``BrowserReplDocumentAuthority``: every decision on a
    /// document, URL or tab the driver makes is its verdict.
    private var authority: BrowserReplDocumentAuthority {
        lock.withLock {
            BrowserReplDocumentAuthority(sessionID: sessionID, policy: domainPolicy, fileRoots: fileRoots.map(\.path), workspaceID: workspaceID)
        }
    }

    /// `panel` as the authority judges it.
    @MainActor
    private func tabFacts(_ panel: BrowserPanel) -> BrowserReplTabFacts {
        tabFacts(panel, workspaceID: Self.browserPanelEntries().first { $0.panel.id == panel.id }?.workspace.id)
    }

    /// The frame gate's scope in `webView`: this session, its directories
    /// and workspace, and the tab that shows the web view as the authority
    /// judges it, in the workspace that holds it now, so the gate refuses
    /// every later script and input step once the tab moved out of the
    /// session's workspace (``BrowserReplFrameGate/checkTab(in:)``). A web
    /// view no attached tab shows (the last session left a tab the user
    /// moved to another workspace) counts as a user's tab in the workspace
    /// that holds it now, and one no workspace holds is refused: the
    /// session's workspace is always judged.
    @MainActor
    private func frameGateScope(_ webView: WKWebView) -> BrowserReplFrameGate.Scope {
        guard let panel = BrowserReplTabAttachments.shared.attachment(showing: webView)?.panel else {
            let holder = Self.browserPanelEntries().first { $0.panel.webView === webView }
            return BrowserReplFrameGate.Scope(
                sessionID: sessionID,
                fileRoots: currentFileRoots,
                tab: BrowserReplTabFacts(id: holder?.panel.id, mainFrameURL: webView.url, workspaceID: holder?.workspace.id),
                workspaceID: workspaceID
            )
        }
        return BrowserReplFrameGate.Scope(
            sessionID: sessionID,
            fileRoots: currentFileRoots,
            tab: tabFacts(panel, workspaceID: panel.workspaceId),
            workspaceID: workspaceID
        )
    }

    /// `panel`, held by the workspace `workspaceID`, as the authority judges it.
    @MainActor
    private func tabFacts(_ panel: BrowserPanel, workspaceID: UUID?) -> BrowserReplTabFacts {
        let attachment = BrowserReplTabAttachments.shared.attachment(for: panel.id)
        return BrowserReplTabFacts(
            id: panel.id,
            mainFrameURL: panel.webView.url,
            creatorSessionID: attachment?.liveCreatorSessionID,
            attachedSessionIDs: Set(attachment?.sessionIDs ?? []),
            workspaceID: workspaceID
        )
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {
        lock.withLock { sink = eventSink }
    }

    func detach() {
        detach(ending: .closed)
    }

    /// Ends the session's hold on its tabs; the tabs it opened close, except
    /// one the user can see when it idled out (``BrowserReplSessionEnd/closesOpenedTab(visibleToUser:)``).
    func detach(ending: BrowserReplSessionEnd) {
        let pendingPolicy = lock.withLock {
            sink = nil
            isDetached = true
            return policyRunner
        }
        // `sessionID` is this instance's own (never reused for a later
        // session of the same name), so this teardown reaches only state
        // this instance made; it runs after the policy task it would race.
        let sessionID = self.sessionID
        Task { @MainActor in
            await pendingPolicy.idle()
            // Keys and buttons the session left pressed are released through
            // its own input guards, before it leaves its tabs.
            for attachment in BrowserReplTabAttachments.shared.attachments(forSession: sessionID) {
                await self.releaseHeldInput(on: attachment)
            }
            BrowserReplPolicyBoard.shared.removeSession(sessionID)
            BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
            // The compiled domain-policy list must not outlive the session
            // in WebKit's persistent rule list store.
            if let ruleLists = self.ruleLists {
                Task { @MainActor in _ = try? await ruleLists.update(rules: nil) }
            }
            self.clearSessionLabels()
            self.closeOpenedTabs(ending: ending)
            // The agent's proxy ends with the session: a tab it kept, now
            // the user's, and any tab opened from one on the same private
            // store go back to the browser's own proxy settings, which every
            // tab applies again on this notification.
            self.proxyDataStore = nil
            if BrowserReplProxyStores.shared.sessionEnded(sessionID) {
                NotificationCenter.default.post(name: .browserSystemProxySettingsDidChange, object: nil)
            }
            self.releaseDownloadWaiters()
            for directory in self.fileChooserDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            self.fileChooserDirectories.removeAll()
        }
    }

    /// Releases what this session, which is ending, holds down in the tab
    /// of `attachment`: each key it holds gets its key-up and its press in
    /// progress its button-up (or its drag ends). These are trusted events,
    /// so they go through the guards the session's input goes through:
    /// under a domain policy, the frame gate, which keeps every blocked
    /// frame inert while they land and refuses them when the tab's page is
    /// blocked; a local file outside the session's directories refuses them
    /// too. A refused release sends nothing: the session's keys and press
    /// are forgotten without an event (the attachment drops them when the
    /// session leaves the tab). Another session's keys and press stay.
    @MainActor
    private func releaseHeldInput(on attachment: BrowserReplTabAttachment) async {
        let held = attachment.takeHeldInput(of: sessionID)
        guard !held.isEmpty, let panel = attachment.panel else { return }
        // The web view the keys and press were held in; a replacement gets
        // nothing (BrowserReplTabAttachment.deliverRelease checks again
        // after the guard's waits).
        guard let webView = held.target.deliverable(to: panel.webView as? CmuxWebView) else {
            attachment.forgetReleased(held)
            return
        }
        if authority.verdict(BrowserReplAccess(.tabPage(Self.url(panel)), in: tabFacts(panel))) != .allowed {
            attachment.forgetReleased(held)
            return
        }
        do {
            try await frameGate.guardingInput(
                in: webView,
                frames: { await BrowserReplFrameTree.frames(of: webView) },
                checkFocusAfter: false
            ) {
                attachment.deliverRelease(held)
            }
        } catch {
            attachment.forgetReleased(held)
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
        // The secrets other sessions typed into tabs
        // (BrowserReplTypedSecrets) are masked by the session's egress gate,
        // in the same pass as its own (typedSecretRedaction()); screenshots
        // and PDFs get them as capture masks (typedSecretMasks(_:)).
        return result
    }

    /// The session's capture masks plus the secrets other sessions typed.
    @MainActor
    private func typedSecretMasks(_ params: [String: Any]) -> [[String: Any]] {
        (params["secretMasks"] as? [[String: Any]] ?? [])
            + BrowserReplTabAttachments.typedSecrets.captureMasks(forReader: sessionID)
    }

    /// Runs `capture` with the typed-secret masks it takes, and refuses its
    /// result (`stale`) when another session typed a secret meanwhile: that
    /// value is not among the masks, and the capture's pixels may show it.
    @MainActor
    private func withTypedSecretMasks<T>(_ params: [String: Any], _ capture: ([[String: Any]]) async throws -> T) async throws -> T {
        let typed = BrowserReplTabAttachments.typedSecrets
        let mark = typed.captureMark(forReader: sessionID)
        let result = try await capture(typedSecretMasks(params))
        guard !typed.typedSince(mark, forReader: sessionID) else {
            throw Self.error("stale", "Another session typed a secret into a tab while the capture was taken, so it may show the value unmasked; try again")
        }
        return result
    }

    @MainActor
    private func dispatchAttached(method name: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        await lock.withLock({ policyRunner }).idle()
        // Ready before any tab of the session exists to need it.
        await BrowserReplTabAttachments.shared.prepareFailClosedRules()
        if let policyFailure { return .failure(policyFailure) }
        // Default deny: a method outside the guard table runs nothing.
        guard let method = BrowserReplDriverMethod(rawValue: name) else {
            return .failure(BrowserReplMethodSpec.unknownMethodError(name))
        }
        let spec = method.spec
        var decoded = JSONSerialization.browserReplObject(paramsJSON)
        // frame.evaluate's world is decided once, before anything runs: the
        // same value routes the input window below and picks the world (and
        // so the user gesture) in `evaluate`. An unknown one is `invalid`.
        let evaluationWorld: BrowserReplEvaluationWorld?
        if method == .frameEvaluate {
            do {
                let world = try BrowserReplEvaluationWorld(parameter: decoded["world"])
                decoded["world"] = world.rawValue
                evaluationWorld = world
            } catch {
                return .failure(error as? BrowserReplDriverError ?? Self.error("invalid", error.localizedDescription))
            }
        } else {
            evaluationWorld = nil
        }
        let params = decoded
        // Every call on a tab first wakes a hibernated tab and waits until
        // the tab renders like a focused foreground page; input must not race
        // WebKit's focus update. Closing or keeping a tab leaves it as it is.
        var tabToPrepare: BrowserPanel?
        if BrowserReplTabWaker.wakesHibernatedTab(name),
           let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
           let panel = try? reachablePanel(id) {
            // Attaching keeps the tab rendering, which starts the restore of
            // a hibernated page (BrowserReplTabAttachment.keepRendering). A
            // tab with as many sessions as it allows is not prepared; the
            // call fails with `limit` when it looks the tab up.
            if (try? attach(panel)) != nil { tabToPrepare = panel }
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
                try checkPage(spec, params: params)
                let attachment = attachment(panel)
                // A dialog the restored page opens while it loads is this
                // session's doing, as is one from its own input.
                let preparation = tabCondition(panel).state == .live
                    ? try await prepareTab(panel, for: name, params: params)
                    : try await attachment.withInput(sessionID: sessionID) {
                        try await prepareTab(panel, for: name, params: params)
                    }
                // WebKit signals the update; the bound only guards a web process
                // that goes away before answering.
                _ = await withTimeout(milliseconds: 2_000) { await attachment.renderingSettled() }
                if preparation == .reloaded {
                    // Loading the crashed or hibernated tab again was the
                    // reload; it waited for DOMContentLoaded, and `waitUntil`
                    // may ask for more within the call's timeout.
                    try await waitForLoadState(panel, Self.waitUntil(params), remainingMilliseconds: Self.remaining(Self.timeout(params), since: started))
                    if spec.judgesLandedPage { try await checkLandedPage(panel) }
                    var result: [String: Any] = [:]
                    if let status = attachment.mainDocumentStatus { result["status"] = status }
                    guard let json = JSONSerialization.browserReplString(result.isEmpty ? nil : result as Any?) else {
                        return .success("null")
                    }
                    return .success(json)
                }
            }
            try checkTab(spec, params: params)
            try checkPage(spec, params: params)
            try await checkLocalDocumentOrigin(spec, params: params)
            let guardsInput = spec.guardsInput && tabToPrepare.map { frameGate.isActive(in: $0.webView) } == true
            if !guardsInput { try await checkFrames(spec, params: params) }
            let value: Any? = try await { () async throws -> Any? in
                if guardsInput, let panel = tabToPrepare {
                    // The input is a point or a key for the whole tab: while it
                    // is in flight, and while it is checked, every frame the
                    // policy blocks is inert (BrowserReplFrameGate.guardingInput),
                    // so a page that moves one under the point, or the focus into
                    // it, after the check does not hand it the event.
                    let webView = panel.webView
                    return try await frameGate.guardingInput(
                        in: webView,
                        frames: { await BrowserReplFrameTree.frames(of: webView) },
                        checkFocusAfter: spec.frames == .focus
                    ) {
                        try await checkFrames(spec, params: params)
                        return try await attachment(panel).withInput(sessionID: sessionID) {
                            try await handle(method: method, params: params)
                        }
                    }
                } else if Self.isActionOnPage(name), let panel = tabToPrepare {
                    // What the page opens while it handles this session's input
                    // goes to this session, never to cmux's UI in front of the user.
                    return try await attachment(panel).withInput(sessionID: sessionID) {
                        try await handle(method: method, params: params)
                    }
                } else if evaluationWorld?.holdsSessionInput == true, let panel = tabToPrepare {
                    // The agent's own page script (el.click(), form.submit()):
                    // what it opens goes to the session, for at most a second,
                    // so a long script leaves the user's dialogs and popups alone.
                    // The runtime's own reads run in the agent world and hold none.
                    return try await attachment(panel).withInput(sessionID: sessionID, atMost: .seconds(1), sleeper: sleeper) {
                        try await handle(method: method, params: params)
                    }
                } else {
                    return try await handle(method: method, params: params)
                }
            }()
            // A tab the session may no longer use (the user moved it to
            // another workspace while the call ran) hands back nothing.
            try checkTab(spec, params: params)
            // A method that leaves the page (navigate, history, reload)
            // fails when the page it landed on is one the authority refuses.
            if spec.judgesLandedPage, let panel = targetPanel(params) {
                try await checkLandedPage(panel)
            }
            if let raw = value as? BrowserReplRawJSON { return .success(raw.text) }
            // Page URLs in the result (BrowserReplPageURL) become this
            // session's form of them here.
            guard let json = BrowserReplDriverOutput(reader: sessionID).result(value) else {
                return .failure(Self.error("invalid", "Driver result for \(name) is not JSON"))
            }
            return .success(json)
        } catch let error as BrowserReplDriverError {
            return .failure(error)
        } catch {
            return .failure(Self.error("invalid", error.localizedDescription))
        }
    }

    @MainActor
    private func handle(method: BrowserReplDriverMethod, params: [String: Any]) async throws -> Any? {
        switch method {
        case .tabsList: return try listTabs(all: params["all"] as? Bool == true).map(listedTabRow)
        case .historySearch: return try searchHistory(params)
        case .tabsDataStore: return try dataStore(params)
        case .tabsOpen: return try await openTab(params)
        case .tabsClose: return try closeTab(params)
        case .tabsActivate, .tabBringToFront: return try activateTab(params)
        case .tabKeep: return try keepTab(params)
        case .tabHandleEvents: return try handleEvents(params)
        case .sessionName: return try nameSession(params)
        case .sessionConfigure: return try await configureSession(params)
        case .tabNavigate: return try await navigate(params)
        case .tabHistory: return try await history(params)
        case .tabReload: return try await reload(params)
        case .tabInfo: return try await info(params)
        case .tabSetViewport: return try setViewport(params)
        case .framesList: return try await listFrames(params)
        case .frameEvaluate: return try await evaluate(params)
        case .frameOwnerBox: return try await ownerBox(params)
        case .frameContentFrame: return try await contentFrame(params)
        case .frameContentFrames: return try await contentFrames(params)
        case .inputMouse: return try await mouse(params)
        case .inputKey: return try await key(params)
        case .inputInsertText: return try await insertText(params)
        case .inputDrag: return try await drag(params)
        case .inputSetFiles: return try await setFiles(params)
        case .fileChooserRespond: return try await respondToFileChooser(params)
        case .dialogRespond: return try respondToDialog(params)
        case .downloadPath: return try await downloadPath(params)
        case .tabScreenshot: return try await screenshot(params)
        case .tabPDF: return try await pdf(params)
        case .cookiesGet: return try await cookies(params)
        case .cookiesSet: return try await setCookies(params)
        case .cookiesClear: return try await clearCookies(params)
        case .clipboardRead: return try readClipboard(params)
        case .clipboardWrite: return try writeClipboard(params)
        case .authRequest:
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
            // What the user types goes into the page like a typed secret,
            // under the same checks: only a tab this session created runs
            // under its domain policy, which the session made sure keeps
            // the page on the credential's domains (its site;
            // BrowserReplBoundary.prepare sends them as secretDomains), and
            // the frame that receives the values must be on them.
            let sessionID = self.sessionID
            let creator = BrowserReplTabAttachments.shared.attachment(for: panel.id)?.liveCreatorSessionID
            guard creator == sessionID else {
                throw Self.error("invalid", "sites.browserAuth fills only a tab this session opened (tabs.open), where its domain policy keeps the page from sending the values elsewhere; this tab is \(creator == nil ? "the user's" : "another session's")")
            }
            let domains = (params["secretDomains"] as? [[String: Any]] ?? []).compactMap(BrowserReplDomainPattern.from(json:))
            guard !domains.isEmpty else {
                throw Self.error("invalid", "auth.request needs the credential's domains, which only a REPL session sends")
            }
            // Its origin and its URL's host, as WebKit recorded them, are
            // each on the credential's domains: a page can relax
            // `document.domain` onto a parent domain on the list.
            let fieldsDocument = frame.info.map(BrowserReplFrameDocument.init(info:)) ?? BrowserReplFrameDocument(url: panel.webView.url)
            guard BrowserReplCredentialRequest.frameOrigin(frame.info, panel.webView) != nil,
                  fieldsDocument.isOn(secretDomains: domains) else {
                throw Self.error("blocked", "the sign-in fields are in a frame showing \(frame.url), outside the credential's domains (\(domains.map(\.raw).joined(separator: ", ")))")
            }
            let tabAttachment = attachment(panel)
            let webView = panel.webView
            let tab = panel.id.uuidString
            return await BrowserReplCredentialRequest.run(
                webView: webView, frameInfo: frame.info, params: params,
                fillSource: bundle.readResource("sites/auth-fill.js"),
                // Recorded before the fill, on the fill's main-actor turn:
                // every session that reads the tab, this one included, gets
                // the values masked in results, events and captures.
                record: { values in
                    for (field, value) in values.sorted(by: { $0.key < $1.key }) {
                        try BrowserReplTabAttachments.typedSecrets.recordCredential(tab: tab, field: field, value: value, domains: domains)
                    }
                },
                stillAllowed: { [weak self, weak panel] in
                    // The session still runs and drives this tab, which still
                    // shows the web view the sheet was asked for.
                    guard let self, let panel, !self.lock.withLock({ self.isDetached }) else { return false }
                    return panel.webView === webView && tabAttachment.sessionIDs.contains(sessionID)
                }
            )
        }
    }

    static func error(_ code: String, _ message: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: code, message: message)
    }

    /// The tab `params.targetId` names, when the driver can reach it.
    @MainActor
    private func targetPanel(_ params: [String: Any]) -> BrowserPanel? {
        guard let raw = params["targetId"] as? String, let id = UUID(uuidString: raw) else { return nil }
        return try? reachablePanel(id)
    }

    /// The tab capability the method needs (``BrowserReplMethodSpec/target``),
    /// judged by the authority on the tab `targetId` names. A tab the
    /// session may no longer reach (the user moved it to another workspace
    /// while the call ran) fails the call, never passes as a missing tab.
    @MainActor
    private func checkTab(_ spec: BrowserReplMethodSpec, params: [String: Any]) throws {
        guard let capability = spec.capability,
              let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
              let panel = try reachablePanel(id) else { return }
        try authority.verdict(BrowserReplAccess(in: tabFacts(panel), capability: capability)).check()
    }

    /// The method's page check (``BrowserReplMethodSpec/page``): a read or
    /// input on a tab whose page the authority refuses (a page the domain
    /// policy blocks, a local file outside the session's directories), and a
    /// navigation to a URL it refuses.
    @MainActor
    private func checkPage(_ spec: BrowserReplMethodSpec, params: [String: Any]) throws {
        switch spec.page {
        case .none:
            return
        case .loadURL:
            guard let url = params["url"] as? String else { return }
            try authority.verdict(BrowserReplAccess(.load(url))).check()
        case .tabPage:
            // A hibernated tab has no page yet; its recorded URL is what a wake would load.
            guard let panel = targetPanel(params) else { return }
            try authority.verdict(BrowserReplAccess(.tabPage(Self.url(panel)), in: tabFacts(panel))).check()
        }
    }

    /// For a page-checked method on a tab the session did not create whose
    /// page is not a web page or a file by URL: the main frame's document
    /// (an `about:blank` page a file page wrote, or an opaque document such
    /// a file made), as the authority judges it.
    @MainActor
    private func checkLocalDocumentOrigin(_ spec: BrowserReplMethodSpec, params: [String: Any]) async throws {
        guard spec.page == .tabPage, let panel = targetPanel(params) else { return }
        try await checkLocalDocumentOrigin(panel)
    }

    /// `panel`'s main-frame document, when the authority judges its local
    /// documents and its page is neither a web page nor a file by URL.
    @MainActor
    private func checkLocalDocumentOrigin(_ panel: BrowserPanel) async throws {
        let tab = tabFacts(panel)
        guard authority.judgesLocalDocuments(in: tab) else { return }
        // A web page has its own origin; a file page is judged by its path.
        guard !["http", "https", "file"].contains(URL(string: Self.url(panel))?.scheme?.lowercased() ?? "") else { return }
        guard let main = await BrowserReplFrameTree.frames(of: panel.webView).first?.info else { return }
        try authority.verdict(BrowserReplAccess(.document(BrowserReplFrameDocument(info: main)), in: tab)).check()
    }

    /// After a method that leaves the page (``BrowserReplMethodSpec/judgesLandedPage``):
    /// a page the authority refuses (the domain policy blocks it, or a local
    /// file outside the session's directories, or a document of a local
    /// file's origin it may not read) fails the call. A user's tab is left
    /// where it landed, never navigated away.
    @MainActor
    private func checkLandedPage(_ panel: BrowserPanel) async throws {
        guard let url = panel.webView.url?.absoluteString else { return }
        try authority.landedPage(url, in: tabFacts(panel)).check()
        try await checkLocalDocumentOrigin(panel)
    }

    /// The method's frame check (``BrowserReplMethodSpec/frames``) on the
    /// frame tree as it is now: input and captures that would reach a frame
    /// (not only the main frame) the authority refuses. Calls that run
    /// script in one frame are judged where they run
    /// (`BrowserReplFrameGate.callAsyncJavaScript`).
    @MainActor
    private func checkFrames(_ spec: BrowserReplMethodSpec, params: [String: Any]) async throws {
        switch spec.frames {
        case .pointer, .drag, .focus, .allFrames:
            break
        case .screenshot, .dialogDocument, .fileChooser, .inFrame, .none:
            // A screenshot is judged during the capture, which blanks blocked
            // frames (BrowserReplFrameGate.coverBlockedFrames); a dialog's
            // document and a file chooser's frame where they are answered;
            // script where it runs.
            return
        }
        guard let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
              let panel = try? reachablePanel(id), frameGate.isActive(in: panel.webView) else { return }
        let webView = panel.webView
        let frames = await BrowserReplFrameTree.frames(of: webView)
        switch spec.frames {
        case .pointer:
            let position = BrowserReplTabAttachments.shared.attachment(for: id)?.mousePosition ?? .zero
            let point = CGPoint(
                x: (params["x"] as? NSNumber)?.doubleValue ?? position.x,
                y: (params["y"] as? NSNumber)?.doubleValue ?? position.y
            )
            try await frameGate.checkPointer(at: [point], in: webView, frames: frames)
        case .drag:
            try await frameGate.checkPointer(at: Self.dragTrail(params), in: webView, frames: frames)
        case .focus:
            try await frameGate.checkFocus(in: webView, frames: frames)
        case .allFrames:
            // A PDF is laid out for print; its frames' boxes cannot be
            // blanked, so any blocked frame refuses it.
            try frameGate.checkCapture(in: webView, frames: frames)
        case .screenshot, .dialogDocument, .fileChooser, .inFrame, .none:
            return
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
        try attach(panel).keepRendering()
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
        Self.browserPanelEntries()
    }

    @MainActor
    private static func browserPanelEntries() -> [(panel: BrowserPanel, workspace: Workspace)] {
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

    /// A tab this session may drive (``BrowserReplDocumentAuthority``,
    /// ``BrowserReplTabCapability/use``): one of its workspace's browser
    /// surfaces, never a tab another live session created (`denied`, naming
    /// that session: that tab's page, cookies, storage and clipboard are the
    /// other session's), and never a tab of another workspace (`denied`: that
    /// needs an attach a person grants, which cmux does not offer yet).
    @MainActor
    private func reachablePanel(_ id: UUID) throws -> BrowserPanel? {
        if let own = try browserPanels().first(where: { $0.id == id }) { return try drivable(own) }
        if let other = allBrowserPanels().first(where: { $0.panel.id == id })?.panel { return try drivable(other) }
        // A tab a relaunch restored but has not loaded yet is a placeholder
        // until first use; using it creates its browser, which then loads
        // like a hibernated tab (prepareTab). Creating it shows nothing. One
        // of another workspace is refused before anything is created.
        for workspace in allWorkspaces() {
            guard let deferred = workspace.panels[id] as? DeferredBrowserPanel else { continue }
            try authority.verdict(BrowserReplAccess(in: BrowserReplTabFacts(id: id, workspaceID: workspace.id), capability: .use)).check()
            return workspace.materializeDeferredBrowserPanel(deferred)
        }
        return nil
    }

    /// `panel`, when the authority lets this session use it
    /// (``BrowserReplTabCapability/use``): not another live session's tab.
    @MainActor
    private func drivable(_ panel: BrowserPanel) throws -> BrowserPanel {
        try authority.verdict(BrowserReplAccess(in: tabFacts(panel), capability: .use)).check()
        return panel
    }

    /// The live session other than this one that created tab `id`, if any.
    @MainActor
    private func otherSessionOwning(_ id: UUID) -> String? {
        BrowserReplTabAttachments.shared.attachment(for: id)?.ownerRefusing(sessionID)
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

    /// `address` (the tab's, by default) as this session may read it
    /// (``BrowserReplPageURL/tabAddress(_:liveCreator:reader:documentLocation:)``):
    /// as written in a tab it created, as `documentLocation` (the main
    /// document's `location.href` it read through its frame gate), and
    /// otherwise without its credential values.
    @MainActor
    private func tabAddress(_ panel: BrowserPanel, address: String? = nil, documentLocation: String? = nil) -> BrowserReplPageURL {
        BrowserReplPageURL.tabAddress(
            address ?? Self.url(panel),
            liveCreator: BrowserReplTabAttachments.shared.attachment(for: panel.id)?.liveCreatorSessionID,
            reader: sessionID,
            documentLocation: documentLocation
        )
    }

    /// The tab's address for a result: in a tab another session or the
    /// user owns, the main document's `location.href` read through this
    /// session's frame gate, as a script it may run there reads it; the
    /// address without credential values when the gate refuses the
    /// document, a dialog holds its script or the read does not answer.
    @MainActor
    private func readableTabAddress(_ panel: BrowserPanel) async -> BrowserReplPageURL {
        guard BrowserReplTabAttachments.shared.attachment(for: panel.id)?.liveCreatorSessionID != sessionID,
              !attachment(panel).hasPendingDialog,
              let mainFrame = try? await frame(panel, [:]) else { return tabAddress(panel) }
        let webView = panel.webView
        let location = await withTimeout(milliseconds: 2_000) { () -> String? in
            let value = try? await self.frameGate.callAsyncJavaScript(
                "return location.href;",
                arguments: [:],
                in: webView,
                frame: mainFrame,
                contentWorld: BrowserReplDriverWorld.world
            )
            return value as? String
        } ?? nil
        return tabAddress(panel, documentLocation: location)
    }

    /// Wakes a hibernated tab before `method` and waits, at most
    /// ``BrowserReplTabWaker/defaultTimeout``, for its page to load again,
    /// or fails with why the tab cannot run it (crashed, a restore the user
    /// stopped). Waking renders the tab off screen; it never shows or
    /// focuses it.
    @MainActor
    private func prepareTab(_ panel: BrowserPanel, for method: String, params: [String: Any]) async throws -> BrowserReplTabPreparation {
        let label = BrowserReplTabLabel(id: panel.id.uuidString, title: Self.title(panel), url: tabAddress(panel).string(for: sessionID))
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

    /// - Throws: `limit` when the tab already has as many sessions as it
    ///   allows (``BrowserReplTabSessionLimit``).
    @MainActor
    @discardableResult
    private func attach(_ panel: BrowserPanel) throws -> BrowserReplTabAttachment {
        // The tab carries this session's options only if this session
        // created it (BrowserReplTabAttachment.contextOptions).
        try BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID, world: sessionWorld.agent) { [weak self] name, payload in
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
            proxyDataStore = try Self.proxyDataStore(params["proxy"] as? [String: Any], sessionID: sessionID)
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
    /// `nil` to clear it. The proxy is `sessionID`'s and ends with it
    /// (``BrowserReplProxyStores``).
    @MainActor
    private static func proxyDataStore(_ proxy: [String: Any]?, sessionID: String) throws -> WKWebsiteDataStore? {
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
        BrowserReplProxyStores.shared.register(store, sessionID: sessionID)
        return store
    }

    @MainActor
    private func attachment(_ panel: BrowserPanel) -> BrowserReplTabAttachment {
        if let attachment = BrowserReplTabAttachments.shared.attachment(for: panel.id) { return attachment }
        // No session drives the tab, so the per-tab limit admits this one,
        // if the session may still use the tab: a call in flight when the
        // tab moved to another workspace does not attach it there again
        // (BrowserReplTabAttachment.workspaceDidChange). The unregistered
        // attachment then has no session and reaches none.
        guard authority.verdict(BrowserReplAccess(in: tabFacts(panel), capability: .use)) == .allowed else {
            return BrowserReplTabAttachment(panel: panel)
        }
        return (try? attach(panel)) ?? BrowserReplTabAttachment(panel: panel)
    }

    @MainActor
    private func forward(_ name: String, _ payload: [String: Any]) {
        // Default deny: an event outside the guard table never reaches the
        // session (BrowserReplEventSpec).
        guard BrowserReplEventSpec.spec(for: name) != nil else { return }
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
        // Page URLs become this session's form of them. The session's egress
        // gate masks secrets, the ones other sessions typed too.
        guard let json = BrowserReplDriverOutput(reader: sessionID).event(payload) else { return }
        let sink = lock.withLock { self.sink }
        sink?(name, json)
    }

    /// A `tabs.list` row with its URL a page URL of the tab's live creator
    /// (``BrowserReplPageURL``): any other session, and the user's tabs, list
    /// it without its credential values.
    @MainActor
    private func listedTabRow(_ row: [String: Any]) -> [String: Any] {
        let creator = (row["targetId"] as? String).flatMap(UUID.init(uuidString:))
            .flatMap { BrowserReplTabAttachments.shared.attachment(for: $0)?.creatorSessionID }
        var row = row
        if let url = row["url"] as? String { row["url"] = BrowserReplPageURL(url, creator: creator) }
        return row
    }

    /// `tabs.list`: the tabs of the session's workspace, in window order;
    /// with `all`, then the tabs of other workspaces the authority lists
    /// (``BrowserReplDocumentAuthority/listing(of:)``): only tabs the
    /// session created that moved there. A user's tab of another workspace
    /// is not listed, and neither is its data store: reaching it needs an
    /// attach a person grants, which cmux does not offer yet.
    @MainActor
    private func listTabs(all: Bool = false) throws -> [[String: Any]] {
        let workspace = try workspace()
        let panels = try browserPanels()
        let authority = self.authority
        let active = activeTargetID.flatMap(UUID.init(uuidString:)).flatMap { id in panels.first { $0.id == id } }
            ?? panels.first { $0.id == workspace.focusedPanelId }
        var rows = listedRows(workspace, active: active, authority: authority)
        if all {
            for other in allWorkspaces() where other.id != workspace.id {
                rows += listedRows(other, active: nil, authority: authority)
            }
        }
        return rows
    }

    /// The rows of `workspace`'s tabs the authority lists, in window order.
    /// A relaunch's not-yet-loaded tabs list in their places, hibernated.
    @MainActor
    private func listedRows(_ workspace: Workspace, active: BrowserPanel?, authority: BrowserReplDocumentAuthority) -> [[String: Any]] {
        let deferred = Self.deferredTabRows(workspace)
        return workspace.orderedPanelIds.compactMap { id in
            if let row = deferred[id] {
                // A tab a relaunch restored is the user's.
                return authority.listing(of: BrowserReplTabFacts(id: id, workspaceID: workspace.id)) == .hidden ? nil : row
            }
            guard let panel = workspace.panels[id] as? BrowserPanel else { return nil }
            var entry: [String: Any] = [
                "targetId": panel.id.uuidString,
                "title": Self.title(panel),
                "url": Self.url(panel),
                "active": panel.id == active?.id,
                "windowId": workspace.id.uuidString,
                "state": tabCondition(panel).state.rawValue,
            ]
            switch authority.listing(of: tabFacts(panel, workspaceID: workspace.id)) {
            case .hidden:
                return nil
            case .ownedByAnotherSession(let owner):
                // Listed with its owner and without its data store; this
                // session cannot use it.
                entry["ownerSession"] = BrowserReplSessionKey(instanceID: owner)?.name ?? owner
            case .usable:
                entry["dataStore"] = Self.dataStoreID(panel.webView.configuration.websiteDataStore)
            }
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
        // script, or without WebKit's switches for the asynchronous Clipboard
        // API and script paste, no page may run in such a tab.
        guard BrowserReplPageClipboard.isSupported else {
            throw Self.error("unsupported", "This WebKit cannot turn its asynchronous Clipboard API or script paste off, so a page in a tab the session opens could use the system clipboard; tabs.open is refused")
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
        try attach(panel).markCreated(by: sessionID)
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
            try await checkLandedPage(panel)
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
    /// (or the default profile's) without `dataStore`, else the store a tab
    /// the authority lets this session use has with that id
    /// (``BrowserReplDocumentAuthority/dataStore(_:among:)``), and that
    /// tab's profile: another live session's private or proxy store stays
    /// its own, and another workspace's private profile store stays there.
    @MainActor
    private func dataStoreForNewTab(_ raw: Any?) throws -> (WKWebsiteDataStore?, UUID?) {
        guard let raw else { return (proxyDataStore, nil) }
        guard let id = raw as? String else {
            throw Self.error("invalid", "tabs.open: dataStore must be a string from tabs.list or tabs.dataStore")
        }
        if let proxyDataStore, Self.dataStoreID(proxyDataStore) == id { return (proxyDataStore, nil) }
        let candidates = allBrowserPanels().map { entry in
            BrowserReplDataStoreCandidate(
                tab: tabFacts(entry.panel, workspaceID: entry.workspace.id),
                storeID: Self.dataStoreID(entry.panel.webView.configuration.websiteDataStore),
                store: entry.panel
            )
        }
        if let panel = authority.dataStore(id, among: candidates) {
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
        // The workspace that holds the tab closes it (the authority let this
        // session close it: its own tab, or a user's tab of its workspace it
        // drives). What is kept for the tab (its
        // attachment, the secrets sessions typed into it) is forgotten when
        // the tab really closes (`BrowserPanel.close()`), never here: a
        // close the workspace refuses leaves the tab open, and its typed
        // values must stay masked for every other session.
        let workspace = try allBrowserPanels().first { $0.panel.id == panel.id }?.workspace ?? workspace()
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
        guard let workspace = Self.holdingWorkspace(of: panelID) else { return }
        workspace.setPanelAutomationLabel(panelId: panelID, label: sessionLabel)
        if sessionLabel == nil { labeledTargetIDs.remove(panelID) } else { labeledTargetIDs.insert(panelID) }
    }

    @MainActor
    private func clearSessionLabels() {
        let labeled = labeledTargetIDs
        labeledTargetIDs.removeAll()
        for id in labeled { Self.holdingWorkspace(of: id)?.setPanelAutomationLabel(panelId: id, label: nil) }
    }

    /// The workspace, of any window, that holds the browser tab `panelID`
    /// now: a tab moves between workspaces, so the session's own workspace
    /// is not where to look for a tab it opened.
    @MainActor
    private static func holdingWorkspace(of panelID: UUID) -> Workspace? {
        browserPanelEntries().first { $0.panel.id == panelID }?.workspace
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
        attachment(panel).rememberCredentials(in: url, sessionID: sessionID)
        _ = attachment(panel).takeAuthenticationFailure()
        // Until the navigation commits, a dialog the page opens (beforeunload)
        // is this session's doing; while the new page loads, it is not.
        let outcome = try await attachment(panel).withInput(sessionID: sessionID) {
            let ticket = try self.beginNavigation(panel, to: url, raw: raw)
            return try await self.waitForNavigation(ticket, in: panel, milliseconds: timeout, what: "navigating to \"\(raw)\"")
        }
        try checkTabUse(panel)
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
        // The landed page was judged after this returns (judgesLandedPage).
        // The session's own URL until the tab has an address; then the
        // address as the session may read it.
        var result: [String: Any] = ["url": panel.webView.url == nil ? raw : await readableTabAddress(panel)]
        if let status = attachment(panel).mainDocumentStatus { result["status"] = status }
        return result
    }

    /// Starts `panel`'s navigation to `url`. A local file loads with read
    /// access to the session directory that holds it, checked and granted
    /// while no REPL session can rename an entry
    /// (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:_:)``): a link
    /// another session swaps in after the session's check leads the load
    /// nowhere outside that directory.
    @MainActor
    private func beginNavigation(_ panel: BrowserPanel, to url: URL, raw: String) throws -> BrowserAutomationNavigationTicket {
        guard url.scheme?.lowercased() == "file" else {
            return panel.beginAutomationNavigation(to: url, recordTypedNavigation: false)
        }
        let roots = lock.withLock { fileRoots }
        return try BrowserReplFileSandbox.withPinnedFileAccess(raw, roots: roots) { readAccess in
            panel.beginAutomationNavigation(to: url, recordTypedNavigation: false, fileReadAccessURL: readAccess)
        }
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
        // An entry the authority refuses is not gone to: the user's tab
        // stays where it is. The page it lands on is judged again after
        // (BrowserReplMethodSpec.judgesLandedPage): a redirect can differ.
        try authority.landedPage(item.url.absoluteString, in: tabFacts(panel)).check()
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
            return try await self.waitForNavigation(ticket, in: panel, milliseconds: timeout, what: "navigating history")
        }
        try checkTabUse(panel)
        // A history entry is the user's and every session's: only the tab's
        // live creator reads its credential values.
        try Self.check(outcome, url: tabAddress(panel, address: item.url.absoluteString).string(for: sessionID))
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
        if webView.url == nil { return ["url": tabAddress(panel, address: item.url.absoluteString)] }
        return ["url": await readableTabAddress(panel)]
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
            let outcome = try await self.waitForNavigation(ticket, in: panel, milliseconds: timeout, what: "reloading")
            return (outcome, target)
        }
        try checkTabUse(panel)
        try Self.check(outcome, url: tabAddress(panel, address: target.absoluteString).string(for: sessionID))
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
        // Like goto, reload answers with the main document's HTTP status.
        if let status = attachment(panel).mainDocumentStatus { return ["status": status] }
        return nil
    }

    /// Waits for the session's navigation `ticket` of `panel` to commit,
    /// at most `milliseconds`. When the session leaves the tab meanwhile
    /// (the user moved it to another workspace) the navigation is stopped
    /// before it commits (``BrowserReplTabAttachment/whileNavigating(sessionID:stop:_:)``).
    @MainActor
    private func waitForNavigation(
        _ ticket: BrowserAutomationNavigationTicket,
        in panel: BrowserPanel,
        milliseconds: Int,
        what: String
    ) async throws -> BrowserAutomationNavigationOutcome {
        try await attachment(panel).whileNavigating(sessionID: sessionID, stop: { [weak panel] in
            guard let panel else { return }
            panel.automationNavigationCoordinator.stop(ticket, loading: panel.webView)
        }) {
            try await withTimeoutThrowing(milliseconds: milliseconds, what: what) {
                await panel.finishAutomationNavigation(ticket)
            }
        }
    }

    /// Throws `denied` when the session may no longer use `panel` (the
    /// user moved it to another workspace while a navigation waited).
    @MainActor
    private func checkTabUse(_ panel: BrowserPanel) throws {
        try authority.verdict(BrowserReplAccess(in: tabFacts(panel), capability: .use)).check()
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
                    _ = try await panel.webView.browserReplCallAsyncJavaScript(
                        script,
                        arguments: [:],
                        in: nil,
                        contentWorld: BrowserReplDriverWorld.world,
                        userGesture: false
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
        // From native state the session reads the address without credential
        // values unless it created the tab; the live read below gives the
        // document's own location.
        result["url"] = tabAddress(panel)
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
        // The live read is a read of the page: it runs through the frame
        // gate like every other, so a main document the domain policy
        // blocks is not read and the call answers from native state (the
        // URL and title tabs.list shows), as the guards allow any tab to.
        let mainFrame = try await frame(panel, [:])
        let metrics = await withTimeout(milliseconds: 2_000) { () -> [Any]? in
            let value = try? await self.frameGate.callAsyncJavaScript(
                "return [document.readyState === 'complete' ? 2 : document.readyState === 'interactive' ? 1 : 0, innerWidth, innerHeight, location.href, document.title];",
                arguments: [:],
                in: webView,
                frame: mainFrame,
                contentWorld: BrowserReplDriverWorld.world
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
        result["url"] = tabAddress(panel, documentLocation: href)
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
                // The user and every session share the history: no reader
                // gets its credential values.
                "url": BrowserReplPageURL(entry.url, creator: nil),
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
                        contentWorld: BrowserReplDriverWorld.world
                    )) as? String
                } ?? nil
            }
        }
        // Frame URLs reach the session as tabs.list URLs do; a frame the
        // session's policy blocks is the page's doing, so not even the tab's
        // creator gets its URL as written.
        let creator = BrowserReplTabAttachments.shared.attachment(for: panel.id)?.creatorSessionID
        var result: [[String: Any]] = []
        for (frame, nameTask) in zip(frames, names) {
            let name = await nameTask.value
            let blocked = frameGate.recordedBlockReason(of: frame, in: webView) != nil
            result.append([
                "frameId": frame.frameID,
                "parentFrameId": frame.parentFrameID ?? NSNull(),
                "url": BrowserReplPageURL(frame.url, creator: blocked ? nil : creator),
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

    private static let needsAgentSentinel = BrowserReplEvaluationBody.needsAgentSentinel

    @MainActor
    private func evaluate(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        // Decided in dispatchAttached, which wrote the decision back.
        let world = try BrowserReplEvaluationWorld(parameter: params["world"])
        let source = params["source"] as? String ?? "() => undefined"
        let args = params["args"] as? [Any] ?? []
        let handles = params["handles"] as? [String] ?? []
        let timeout = (params["timeoutMs"] as? NSNumber)?.intValue ?? 0
        let run: @MainActor () async throws -> Any? = { [self] in
            if sessionWorld.evaluationWorld(world) === sessionWorld.agent {
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
    /// Throws `invalid`, before anything runs, when `source` is not one
    /// expression on its own (``BrowserReplEvaluationBody``).
    @MainActor
    private static func evaluationBody(source: String, requiresAgent: Bool, elementsExpression: String) throws -> String {
        try BrowserReplEvaluationBody(source: source, requiresAgent: requiresAgent, elementsExpression: elementsExpression).text
    }

    @MainActor
    private func evaluateInAgentWorld(
        _ panel: BrowserPanel,
        _ frame: BrowserReplFrame,
        source: String,
        args: [Any],
        handles: [String]
    ) async throws -> Any? {
        let body = try Self.evaluationBody(
            source: source,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        return try await runEvaluation(panel, frame, body: body, world: sessionWorld.agent, args: args, handles: handles)
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
            let body = try Self.evaluationBody(source: source, requiresAgent: false, elementsExpression: "[]")
            return try await runEvaluation(panel, frame, body: body, world: .page, args: args, handles: [])
        }
        // Built first: a source that is not one expression fails before
        // the bridge is set up in the page.
        let collect = """
        const __bridge = window[__key];
        delete window[__key];
        if (__bridge) window.removeEventListener(__key, __bridge.listener, true);
        if (!__bridge || __bridge.got.length !== __count) return { __cmuxError__: { code: "stale", message: "Element handle is no longer attached to the document", name: "Error" } };
        """
        let body = try collect + "\n" + Self.evaluationBody(source: source, requiresAgent: false, elementsExpression: "__bridge.got")
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
        let dispatch = try Self.evaluationBody(
            source: "(...els) => { for (const el of els) el.dispatchEvent(new CustomEvent(__key, { bubbles: true, composed: true })); return els.length; }",
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        do {
            _ = try await runEvaluation(
                panel,
                frame,
                body: "const __key = \(JSONSerialization.browserReplString(key) ?? "\"\"");\n" + dispatch,
                world: sessionWorld.agent,
                args: [],
                handles: handles
            )
        } catch {
            _ = try? await panel.webView.browserReplCallAsyncJavaScript(
                "const b = window[__key]; if (b) { window.removeEventListener(__key, b.listener, true); delete window[__key]; }",
                arguments: ["__key": key],
                in: frame.info,
                contentWorld: .page,
                userGesture: false
            )
            throw error
        }
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
        // A page-world script runs with a user gesture, with which WebKit
        // lets a page read the system clipboard in a tab without the page
        // clipboard guard (a user's tab): script paste is off while it runs
        // and while the page can still use that gesture
        // (BrowserReplPageClipboard.holdScriptPasteOff). The session's input
        // window (BrowserReplTabAttachment.withInput) holds it too; this one
        // is at the gesture itself.
        var pasteHold: BrowserReplScriptPasteHold?
        if world == WKContentWorld.page {
            guard let hold = BrowserReplPageClipboard.holdScriptPasteOff(in: panel.webView) else {
                throw Self.error("unsupported", "This WebKit cannot turn script paste off, so a page script could read the system clipboard; frame.evaluate in the page world is refused")
            }
            pasteHold = hold
        }
        defer { pasteHold?.release() }
        for attempt in 0..<2 {
            let value: Any?
            do {
                // Runs only while the frame shows a document the domain
                // policy allows; a frame looked up from an earlier tree read
                // may have navigated since.
                // Script in the agent's world runs without a user gesture: a
                // page handler it sets off (focus, a dispatched event) must
                // not hold one, nor the script, with which either could
                // write the system clipboard (execCommand("copy") of a frame's
                // initial empty document is WebKit's own in that world).
                value = try await frameGate.callAsyncJavaScript(
                    body, arguments: arguments, in: panel.webView, frame: frame, contentWorld: world,
                    userGesture: world == WKContentWorld.page
                )
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
        guard let agentSource = bundle.agentInstallSource else {
            throw Self.error("unsupported", "The browser REPL page agent is not bundled")
        }
        // The agent world's own execCommand never runs WebKit's Copy, Cut or
        // Paste (BrowserReplPageClipboard.agentWorldGuardSource): with the
        // gesture of an agent's click they would use the system clipboard.
        let source = BrowserReplPageClipboard.agentWorldGuardSource + agentSource
        attachment(panel).installAgentUserScriptIfNeeded(source: source, sessionID: sessionID)
        do {
            // Without a user gesture: the agent's own code in that world may
            // have replaced what the install script calls.
            _ = try await panel.webView.browserReplEvaluateJavaScriptWithoutGesture(source, in: frame.info, contentWorld: sessionWorld.agent)
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
        let webView = panel.webView
        let frames = await BrowserReplFrameTree.frames(of: webView)
        guard let frameID = params["frameId"] as? String,
              let child = frames.first(where: { $0.frameID == frameID }) else {
            throw Self.error("stale", "Frame is detached")
        }
        guard let parentID = child.parentFrameID, let parent = frames.first(where: { $0.frameID == parentID }) else {
            return ["x": 0, "y": 0, "width": 0, "height": 0]
        }
        // The child's own position in its parent's window.frames, which it
        // reports itself (BrowserReplFrameBinding), names its frame element
        // there; a tree index would name a sibling once a frame in a shadow
        // tree or a removed frame shifts the lists.
        let script = """
        const target = __index >= 0 ? window.frames[__index] : null;
        const length = window.frames.length;
        const find = (root) => {
          for (const el of root.querySelectorAll("iframe, frame")) if (el.contentWindow === target) return el;
          for (const el of root.querySelectorAll("*")) if (el.shadowRoot) { const found = find(el.shadowRoot); if (found) return found; }
          return null;
        };
        const el = target ? find(document) : null;
        if (!el) return { box: null, length };
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        const px = (v) => parseFloat(v) || 0;
        return {
          box: {
            x: r.left + el.clientLeft + px(cs.paddingLeft),
            y: r.top + el.clientTop + px(cs.paddingTop),
            width: el.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight),
            height: el.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom),
          },
          length,
        };
        """
        do {
            let bound = try await frameBinding.bind(
                parentID: parent.frameID,
                in: webView,
                readTree: { await BrowserReplFrameTree.frames(of: webView) },
                body: { [frameGate, world = sessionWorld.agent] positions in
                    // The session's world sees closed shadow roots, where
                    // the frame element may be.
                    let value = try await frameGate.callAsyncJavaScript(
                        script,
                        arguments: ["__index": positions[child.frameID] ?? -1],
                        in: webView,
                        frame: parent,
                        contentWorld: world
                    ) as? [String: Any]
                    return (value?["box"], (value?["length"] as? NSNumber)?.intValue ?? -1)
                }
            )
            guard let bound else {
                throw Self.error("stale", "The page kept changing its frames, so frame \(frameID)'s element is unknown; try again")
            }
            return bound.value ?? NSNull()
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    /// Binds `<iframe>` handles of `frame` to their child frames' ids: one
    /// evaluation maps every handle to its position in `window.frames`,
    /// and each child frame reports its own position there
    /// (``BrowserReplFrameBinding``), so a frame in a shadow tree, or one
    /// the page adds or removes meanwhile, never binds a handle to a
    /// sibling's frame. A handle that cannot be bound gets `nil`.
    @MainActor
    private func childFrameIDs(_ panel: BrowserPanel, _ frame: BrowserReplFrame, elements: [String]) async throws -> [String?] {
        let body = try Self.evaluationBody(
            source: """
            (...els) => {
              const index = new Map();
              for (let i = 0; i < window.frames.length; i++) index.set(window.frames[i], i);
              return {
                positions: els.map((el) => {
                  const w = el && el.contentWindow;
                  return w && index.has(w) ? index.get(w) : -1;
                }),
                length: window.frames.length,
              };
            }
            """,
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => { try { return __agent.element(h); } catch { return null; } })"
        )
        let webView = panel.webView
        let bound = try await frameBinding.bind(
            parentID: frame.info == nil ? nil : frame.frameID,
            in: webView,
            readTree: { await BrowserReplFrameTree.frames(of: webView) },
            body: { [self] _ in
                let raw = try await runEvaluation(panel, frame, body: body, world: self.sessionWorld.agent, args: [], handles: elements)
                guard let text = (raw as? BrowserReplRawJSON)?.text,
                      let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let positions = object["positions"] as? [NSNumber],
                      let length = (object["length"] as? NSNumber)?.intValue else {
                    return (elements.map { _ in -1 }, -1)
                }
                return (positions.map(\.intValue), length)
            }
        )
        guard let bound else { return elements.map { _ in nil } }
        return bound.value.map { bound.children[$0] }
    }

    @MainActor
    private func contentFrame(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        guard let element = params["element"] as? String else {
            throw Self.error("invalid", "element is required")
        }
        guard let id = try await childFrameIDs(panel, frame, elements: [element]).first ?? nil else { return nil }
        return ["frameId": id]
    }

    /// The child frames of many `<iframe>` handles of one frame, in one
    /// binding (``childFrameIDs(_:_:elements:)``). A page of 300 iframes
    /// needed 300 calls. Returns one `{ frameId }` or `null` per handle, in order.
    @MainActor
    private func contentFrames(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        let frame = try await frame(panel, params)
        let elements = params["elements"] as? [String] ?? []
        if elements.isEmpty { return [Any]() }
        return try await childFrameIDs(panel, frame, elements: elements).map { id -> Any in
            id.map { ["frameId": $0] } ?? NSNull()
        }
    }

    // MARK: - Input

    /// Runs `body` with the panel's web view in a window. A hidden pane's web
    /// view has none, so it borrows the offscreen render host for the call.
    ///
    /// The render host runs `body` in a task of its own; that task is
    /// cancelled with the call (its cell timed out, its session was reset),
    /// so each native step's tab check (``BrowserReplFrameGate/checkTab(in:)``)
    /// stops a cancelled call there too.
    @MainActor
    private func withWindow<T: Sendable>(_ panel: BrowserPanel, _ body: @escaping @MainActor (CmuxWebView, NSWindow) async throws -> T) async throws -> T {
        guard let webView = panel.webView as? CmuxWebView else {
            throw Self.error("unsupported", "This tab does not accept native input")
        }
        if let window = webView.window {
            return try await body(webView, window)
        }
        let relay = BrowserReplCancellationRelay()
        return try await withTaskCancellationHandler {
            try await panel.withBrowserReplRenderHost {
                let work = Task { @MainActor () throws -> T in
                    guard let window = webView.window else {
                        throw Self.error("unsupported", "The tab could not be rendered for input")
                    }
                    return try await body(webView, window)
                }
                relay.bind { work.cancel() }
                return try await work.value
            }
        } onCancel: {
            relay.cancel()
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
        // A press that names its target (a locator click) is sent only
        // while the target, and each parent frame's <iframe>, is still at
        // the point: checked in the web content process right before the
        // press, after the page ran since the runtime's own check.
        var pressTarget: BrowserReplPressTarget?
        if type == "down" {
            let press = if let x, let y { CGPoint(x: x, y: y) } else { attachment.mousePosition }
            pressTarget = try BrowserReplPressTarget(expect: params["expect"], press: press)
        }
        try await attachment.waitForPointer(sessionID: sessionID)
        let heldBefore = attachment.holdsPointer(sessionID: sessionID)
        if type == "down" { attachment.pointerPressed(sessionID: sessionID) }
        defer { if type == "up" { attachment.pointerReleased(sessionID: sessionID) } }
        let positionBefore = attachment.mousePosition
        if let x, let y { attachment.mousePosition = CGPoint(x: x, y: y) }
        let css = attachment.mousePosition
        do {
            try await withWindow(panel) { [self] webView, window in
                // Only the modifiers this session holds: another session's held
                // Meta must not turn this click into a chord.
                let flags = modifiers.union(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: self.sessionID))
                if type == "wheel" {
                    // The REPL is untrusted: any number reaches here, and the
                    // counts are clamped to a wheel count's range.
                    guard let delta = BrowserReplWheelDelta(
                        validatingDeltaX: (params["deltaX"] as? NSNumber)?.doubleValue ?? 0,
                        deltaY: (params["deltaY"] as? NSNumber)?.doubleValue ?? 0
                    ) else {
                        throw Self.error("invalid", "mouse.wheel: deltaX and deltaY must be finite numbers")
                    }
                    guard let event = BrowserReplNativeInput.wheelEvent(
                        webView: webView,
                        window: window,
                        cssPoint: css,
                        delta: delta,
                        modifierFlags: flags
                    ) else {
                        throw Self.error("invalid", "Could not create a wheel event")
                    }
                    try self.frameGate.checkTab(in: webView)
                    webView.deliverAutomationMouseEvent(event)
                    await BrowserReplNativeInput.roundTrip(webView)
                    return
                }
                if let pressTarget {
                    try await self.verifyPress(pressTarget, in: webView)
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
        } catch {
            // A refused event was not delivered: the pointer stays where
            // the last delivered one put it, and a refused press holds
            // nothing, so no later event (a release when the session
            // leaves) is sent at the refused point.
            if attachment.mousePosition == css { attachment.mousePosition = positionBefore }
            if type == "down", !heldBefore { attachment.pointerReleased(sessionID: sessionID) }
            throw error
        }
        return nil
    }

    /// Checks that a press (or a drag's release) at `target`'s point still
    /// reaches its element and each parent frame's `<iframe>`, right before
    /// it is sent. The tree is read first: the checks then all start in one
    /// turn and the event follows the last answer with no other suspension
    /// (BrowserReplPressTarget.verify). They run in this session's world,
    /// where its handles live and no other session's code runs.
    @MainActor
    private func verifyPress(_ target: BrowserReplPressTarget, in webView: WKWebView) async throws {
        let frames = await BrowserReplFrameTree.frames(of: webView)
        try await target.verify(frames: frames) { [frameGate, world = sessionWorld.agent] body, arguments, frame in
            try await frameGate.callAsyncJavaScript(
                body,
                arguments: arguments,
                in: webView,
                frame: frame,
                contentWorld: world
            )
        }
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
        attachment: BrowserReplTabAttachment,
        dropAllowed: Bool = true
    ) async throws {
        // Each native step asks the tab capability again
        // (BrowserReplFrameGate.checkTab): a tab moved out of the session's
        // workspace while the call waited gets no further event, and under
        // guarded input neither does a main frame that navigated to a page
        // the authority refuses or to another origin (a drag then ends with
        // no drop when the pointer gesture ends).
        func send() throws {
            try frameGate.checkTab(in: webView)
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
        // A drag is its own session's: one another session's press left
        // (it failed partway) ends without a drop, never consumed here.
        if let drag = attachment.drag, drag.sessionID != sessionID {
            attachment.discardDrag()
        }
        switch type {
        case .leftMouseDown:
            let capture = BrowserAutomationDragCapture()
            webView.automationDragCapture = capture
            attachment.drag = BrowserReplTabAttachment.DragState(sessionID: sessionID, capture: capture)
            do {
                try send()
            } catch {
                attachment.discardDrag()
                throw error
            }
            await BrowserReplNativeInput.waitForPendingMouseEvents(webView)
        case .leftMouseDragged:
            if let drop = attachment.drag?.drop {
                try frameGate.checkTab(in: webView)
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
                    if !BrowserReplDragPasteboardRedirect.shared.install() {
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
            try await startDropIfDragBegan(webView: webView, window: window, location: location, attachment: attachment)
        case .leftMouseUp:
            if attachment.drag?.drop == nil {
                try await startDropIfDragBegan(webView: webView, window: window, location: location, attachment: attachment)
            }
            if let drop = attachment.drag?.drop {
                try frameGate.checkTab(in: webView)
                drop.draggingLocation = location
                let operation = dropAllowed ? webView.draggingUpdated(drop) : []
                await BrowserReplNativeInput.roundTrip(webView)
                if !operation.isEmpty, (try? frameGate.checkTab(in: webView)) != nil, webView.prepareForDragOperation(drop) {
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
    /// it has, enter the web view as the drop destination. A drag WebKit
    /// started after its pasteboard window was diverted (the page's handler
    /// ran past the window's bound, or the tab's drag state was reset)
    /// wrote its data to a discard: it ends without a drop and the call
    /// fails.
    @MainActor
    private func startDropIfDragBegan(
        webView: CmuxWebView,
        window: NSWindow,
        location: NSPoint,
        attachment: BrowserReplTabAttachment
    ) async throws {
        guard let state = attachment.drag, state.drop == nil else { return }
        if !state.capture.didBegin {
            await BrowserReplNativeInput.roundTrip(webView)
        }
        guard state.capture.didBegin else { return }
        if state.capture.lostDragData {
            webView.automationDragCapture = nil
            attachment.drag = nil
            webView.endAutomationDrag(at: location, operation: [])
            await BrowserReplNativeInput.roundTrip(webView)
            throw Self.error("timeout", "The page started the drag after its 5 s pasteboard window, so its drag data was discarded (never put on the system's drag pasteboard) and the drag ended without a drop; make the page's dragstart handler return sooner")
        }
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
                try self.frameGate.checkTab(in: webView)
                let result = webView.replayBrowserReplKeyStroke(stroke, keyDown: type == "down", heldBy: self.sessionID)
                guard result == .delivered else {
                    throw Self.error("invalid", "Could not deliver key \"\(keyName)\"")
                }
                // Watched in the delivery's turn: WebKit reports whether a
                // page handled the key on a later one.
                let outcome = type == "down" && stroke.editingCommand != nil
                    ? webView.browserNativeInputDeliveryOwner.lastDeliveredKeyDown.map { webView.observeAutomationKeyDownOutcome($0) }
                    : nil
                self.attachment(panel).heldKeys.record(stroke, keyDown: type == "down", sessionID: self.sessionID)
                // The editing command runs only for a key no page handled (it
                // did not cancel the keydown), as a browser's Edit menu does.
                if type == "down", let command = stroke.editingCommand, let outcome, await outcome.wasUnhandled() {
                    try await self.performEditingCommand(command, panel: panel, webView: webView)
                }
                await BrowserReplNativeInput.roundTrip(webView)
            }
        }
        return nil
    }

    /// WebKit's command name for each Cocoa clipboard action.
    private static let clipboardCommandNames = ["copy:": "Copy", "cut:": "Cut", "paste:": "Paste"]

    /// Meta+C, Meta+X and Meta+V run only in tabs a session created, on that
    /// tab's virtual clipboard. A user's tab has none (its clipboard is the
    /// system's, which agent input never reaches), so the shortcut is
    /// refused there before any key reaches the page.
    @MainActor
    private func refuseClipboardCommandInUserTab(_ command: String, panel: BrowserPanel) throws {
        guard !attachment(panel).appliesSessionPolicies else { return }
        let name = Self.clipboardCommandNames[command] ?? command
        throw Self.error(
            "unsupported",
            "\(name) is refused in a user's tab (one no attached session opened): the clipboard there is the system's, which agent input never reaches. Open the page with tabs.open() to use the tab's own clipboard"
        )
    }

    /// Runs the Cocoa editing action behind a Command shortcut. Clipboard
    /// actions run on the tab's virtual clipboard and never on a pasteboard
    /// (``BrowserReplFrameGate/runClipboardShortcut(_:clipboard:in:frames:)``):
    /// a script dispatches the `copy`, `cut` or `paste` event in the focused
    /// frame's document, after the gate authorized it, and does the default
    /// action there in the same turn. Only tabs a session created run them,
    /// and what a Copy or Cut took lands only while the creator that held the
    /// tab when it began still does (BrowserReplTabClipboard).
    @MainActor
    private func performEditingCommand(_ command: String, panel: BrowserPanel, webView: CmuxWebView) async throws {
        let attachment = attachment(panel)
        switch command {
        case "copy:", "cut:", "paste:":
            try refuseClipboardCommandInUserTab(command, panel: panel)
            guard let tenure = attachment.clipboard.tenure,
                  let shortcut = BrowserReplFrameGate.ClipboardShortcut(rawValue: String(command.dropLast()))
            else { return }
            // A JavaScript dialog a handler opens meanwhile is answered as an
            // unhandled one, so it cannot hold the shortcut.
            attachment.clipboardCommandsInFlight.append(shortcut.rawValue)
            defer { attachment.clipboardCommandFinished(shortcut.rawValue) }
            let taken = try await frameGate.runClipboardShortcut(
                shortcut,
                clipboard: attachment.clipboard.items(during: tenure),
                in: webView,
                frames: { await BrowserReplFrameTree.frames(of: webView) }
            )
            if let taken { attachment.clipboard.store(taken, during: tenure) }
        case "bold", "italic", "underline":
            // Chrome's editor formats the selection of an editable element on
            // Command+B/I/U; the page sees its usual beforeinput and input.
            _ = try? await webView.browserReplCallAsyncJavaScript(
                """
                const el = document.activeElement;
                if (!(document.designMode === "on" || (el && el.isContentEditable))) return false;
                return document.execCommand(command);
                """,
                arguments: ["command": command],
                in: nil,
                contentWorld: .page,
                userGesture: false
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
        // The check judges the web view the text goes to (`webView`, the
        // one the input captured), never the panel's current one, and the
        // commit types only while the panel still shows it.
        let checkTarget: @MainActor @Sendable (WKWebView) async throws -> Void = { webView in
            guard let name = params["secretName"] as? String else { return }
            // Only a tab this session created runs under its domain policy,
            // which keeps the page from sending the secret elsewhere.
            if let refusal = BrowserReplSecretTarget.tabRefusal(
                name: name,
                creator: BrowserReplTabAttachments.shared.attachment(for: panel.id)?.liveCreatorSessionID,
                sessionID: sessionID
            ) {
                throw refusal
            }
            let frames = await BrowserReplFrameTree.frames(of: webView)
            let rawDomains = params["secretDomains"] as? [[String: Any]] ?? []
            try await BrowserReplSecretGuard.checkSecretTarget(
                name: name,
                domains: rawDomains,
                webView: webView,
                frames: frames
            )
            // The agent may have deleted or set the secret again since the
            // call was made: the value in `text` is then not one the session
            // holds under that name, and is not typed. Asked on the commit's
            // main-actor turn, after the last wait.
            let revision = (params["secretRevision"] as? NSNumber)?.intValue ?? -1
            guard self.lock.withLock({ self.secretCheck })?(name, revision) == true else {
                throw Self.error("invalid", "secret \"\(name)\" was deleted or set again after this call was made, so its earlier value is not typed")
            }
            // Recorded once the domain check passes and before typing, on
            // the same main-actor turn as the commit: other sessions that
            // read the tab do not hold the secret, so the tab keeps it
            // masked for them, also when typing fails partway and part of
            // the value is already in the page. A refused value is never
            // recorded, so it never becomes a mask other sessions see.
            try BrowserReplTabAttachments.typedSecrets.record(
                tab: panel.id.uuidString,
                name: name,
                value: text,
                domains: rawDomains.compactMap(BrowserReplDomainPattern.from(json:)),
                typist: sessionID
            )
        }
        let world = sessionWorld.agent
        let frameGate = frameGate
        try await withWindow(panel) { webView, _ in
            try await BrowserReplNativeInput.insertText(
                text,
                into: webView,
                world: world,
                // Also asked right before the commit: a tab moved out of the
                // session's workspace meanwhile gets no text.
                isCurrent: { [weak panel] in
                    panel?.webView === webView && (try? frameGate.checkTab(in: webView)) != nil
                },
                checkTarget: checkTarget
            )
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
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw Self.error("invalid", "input.drag: every point's x and y must be finite numbers")
        }
        // The session reserved the drag's events against its ledger
        // (BrowserReplResource.inputEvents); this is the same per-call
        // limit for a caller that is not a session.
        let events = 5 * (points.count - 1) + 3
        if let limit = BrowserReplResourceLimits.standard.each(.inputEvents), events > limit {
            throw Self.error("invalid", "input.drag: the path makes \(events) native input events, at most \(limit) a call; use a shorter path")
        }
        let modifiers = BrowserReplKeyStroke.modifierFlags(named: params["modifiers"] as? [String] ?? [])
        // A locator drag names the source its press must reach (`expect`)
        // and the target its release must reach (`dropExpect`), checked as
        // a click's press is (input.mouse), right before the press and
        // right before the drop: the page runs between the runtime's checks
        // and here, and during the drag.
        let pressTarget = try BrowserReplPressTarget(expect: params["expect"], press: first)
        let dropTarget = try BrowserReplPressTarget(expect: params["dropExpect"], press: last)
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
                let flags = modifiers.union(webView.browserNativeInputDeliveryOwner.activeModifierFlags(heldBy: self.sessionID))
                attachment.mouseState.reset()
                _ = attachment.mouseState.eventType(forType: "move", button: .left)
                try await self.deliverMouse(.mouseMoved, button: .left, at: first, clickCount: 0, flags: flags, webView: webView, window: window, attachment: attachment)
                if let pressTarget { try await self.verifyPress(pressTarget, in: webView) }
                _ = attachment.mouseState.eventType(forType: "down", button: .left)
                try await self.deliverMouse(.leftMouseDown, button: .left, at: first, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
                for point in trail {
                    // A cancelled call (its cell timed out, its session
                    // closed) stops between steps.
                    try Task.checkCancellation()
                    try await self.deliverMouse(.leftMouseDragged, button: .left, at: point, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
                }
                _ = attachment.mouseState.eventType(forType: "up", button: .left)
                if let dropTarget {
                    do {
                        try await self.verifyPress(dropTarget, in: webView)
                    } catch let error as BrowserReplDriverError where error.code == "stale" {
                        // No drop: an HTML5 drag ends without one, and a plain
                        // mouse drag is released where it was pressed.
                        try await self.deliverMouse(.leftMouseUp, button: .left, at: first, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment, dropAllowed: false)
                        throw BrowserReplDriverError(code: "stale", message: Self.dropRefusal(error.message))
                    }
                }
                try await self.deliverMouse(.leftMouseUp, button: .left, at: last, clickCount: 1, flags: flags, webView: webView, window: window, attachment: attachment)
            }
            attachment.mousePosition = last
        }
        return nil
    }

    /// A press check's refusal (`no press was sent: …`) worded for the
    /// release of a drag that made no drop.
    private static func dropRefusal(_ message: String) -> String {
        let prefix = "no press was sent: "
        let body = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
        return "no drop was made: " + body.replacingOccurrences(of: "when the press was about to be sent", with: "when the drop was about to be made")
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
        let body = try Self.evaluationBody(
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
        _ = try await runEvaluation(panel, frame, body: body, world: sessionWorld.agent, args: [files], handles: [element])
        return nil
    }

    /// `filechooser.respond`. A cancel always goes through. Files go only
    /// to the session the chooser was routed to, and only into the document
    /// that opened it, judged right before the answer
    /// (``BrowserReplMethodSpec/Frames/fileChooser``): with child-frame
    /// loads held, a fresh frame tree must still show that document in the
    /// chooser's frame (else `stale`) and the authority must allow it (else
    /// `blocked`); the chooser stays open to be cancelled. The files are
    /// staged and the answer sent on the main-actor turn of the check's
    /// last reply, so nothing in this process runs in between; nothing is
    /// written to disk before the check passes.
    @MainActor
    private func respondToFileChooser(_ params: [String: Any]) async throws -> Any? {
        let panel = try panel(params)
        guard let id = params["chooserId"] as? String else {
            throw Self.error("invalid", "chooserId is required")
        }
        let attachment = attachment(panel)
        let gone = Self.error("not_found", "File chooser \(id) is gone")
        if params["cancel"] as? Bool == true {
            guard attachment.respondToFileChooser(id: id, sessionID: sessionID, files: nil) else { throw gone }
            return nil
        }
        guard let frame = attachment.fileChooserFrame(id: id, sessionID: sessionID) else { throw gone }
        let webView = panel.webView
        try await frameGate.loadHold.holding(webView) {
            let frames = await BrowserReplFrameTree.frames(of: webView)
            try await frameGate.checkFileChooser(frame: frame, in: webView, frames: frames)
            guard panel.webView === webView else {
                throw Self.error("stale", "The tab replaced its web view while the file chooser's frame was checked; it may only be cancelled")
            }
            // Only the session the chooser was routed to may answer it, and
            // nothing is written past the staging bounds. This runs in one
            // main-actor turn, so the chooser cannot go between the check
            // and the answer.
            let staged = try BrowserReplUploadStaging(parent: FileManager.default.temporaryDirectory).stage(
                params["files"] as? [[String: Any]] ?? []
            ) {
                attachment.fileChooserFrame(id: id, sessionID: sessionID) === frame
            }
            guard let staged else { throw gone }
            fileChooserDirectories.append(staged.directory)
            guard attachment.respondToFileChooser(id: id, sessionID: sessionID, files: staged.urls) else { throw gone }
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
        guard try attachment(panel).respondToDialog(id: id, sessionID: sessionID, accept: accept, promptText: params["promptText"] as? String) else {
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
    private func closeOpenedTabs(ending: BrowserReplSessionEnd) {
        let opened = openedTargetIDs
        openedTargetIDs.removeAll()
        // Each tab is closed in the workspace that holds it now, of any
        // window: one the user moved out of the session's workspace (or a
        // tab of a workspace that closed meanwhile) closes too, unless
        // `page.keep()` took it out of this set, or the session idled out
        // while the user can see the tab (it stays, as the user's). The
        // panel's own close forgets what is kept for it
        // (`BrowserPanel.close()`), only once it really closes.
        let entries = Self.browserPanelEntries()
        for id in opened {
            guard let entry = entries.first(where: { $0.panel.id == id }) else { continue }
            guard ending.closesOpenedTab(visibleToUser: Self.isVisibleToUser(entry.panel, in: entry.workspace)) else { continue }
            _ = entry.workspace.closePanel(id, force: true)
        }
    }

    /// Whether the user can see `panel` now: its workspace is the selected
    /// one of its window, and its web view is in that window's view tree,
    /// not hidden (the selected tab of its pane), in a visible window that
    /// is not minimized.
    @MainActor
    private static func isVisibleToUser(_ panel: BrowserPanel, in workspace: Workspace) -> Bool {
        let webView = panel.webView
        guard workspace.owningTabManager?.selectedTabId == workspace.id,
              let window = webView.window, window.isVisible, !window.isMiniaturized else { return false }
        return webView.superview != nil && !webView.isHiddenOrHasHiddenAncestor
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
        let frameGate = self.frameGate
        let image: CGImage = try await withTypedSecretMasks(params) { masks in try await withWindow(panel) { webView, _ in
            try await Self.withSecretMasks(masks, gate: frameGate, blockedChildFrames: .handToCapture, webView: webView) { blockedChildFrames in
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
        } }
        let data = try BrowserReplCapture.encode(image, format: format, quality: quality)
        return ["base64": data.base64EncodedString(), "width": image.width, "height": image.height]
    }

    @MainActor
    private func pdf(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        // Refused here: printPDF falls back to a one-page PDF on any error.
        _ = try BrowserReplCapture.pdfLayout(options: params)
        let frameGate = self.frameGate
        let data: Data = try await withTypedSecretMasks(params) { masks in try await withWindow(panel) { [self] webView, _ in
            // A PDF cannot blank a frame: any frame whose marked document
            // the gate blocks (the policy, or a local file the session may
            // not read) refuses it, also one that navigated after
            // checkFramePolicy read the tree.
            try await Self.withSecretMasks(masks, gate: frameGate, blockedChildFrames: .refuse, webView: webView) { _ in
                // No child frame loads a new document while the PDF is
                // printed: one the page created meanwhile could show a
                // blocked page the checks around it never saw.
                guard frameGate.isActive(in: webView) else { return try await self.printPDF(webView: webView, params: params) }
                return try await BrowserReplSubframeLoadHold.shared.holding(webView) {
                    try await self.printPDF(webView: webView, params: params)
                }
            }
        } }
        return ["base64": data.base64EncodedString()]
    }

    /// Runs `capture` with registered secrets masked in frames on their
    /// domains, bound to the documents the frames show, and refuses it when
    /// the main frame, or with `.refuse` any frame, shows a page the gate
    /// blocks (the policy, or in a user's tab a local file the session may
    /// not read); with `.handToCapture` `capture` gets the blocked child
    /// frames to blank (BrowserReplCaptureMask).
    @MainActor
    private static func withSecretMasks<T>(
        _ masks: [[String: Any]],
        gate: BrowserReplFrameGate,
        blockedChildFrames: BrowserReplCaptureMask.BlockedChildFrames,
        webView: WKWebView,
        _ capture: (_ blockedChildFrames: [String: String]) async throws -> T
    ) async throws -> T {
        try await BrowserReplCaptureMask(secretMasks: masks, gate: gate, blockedChildFrames: blockedChildFrames).run(
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
        let panels = try browserPanels().filter { otherSessionOwning($0.id) == nil }
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
        let authority = self.authority
        for url in urls {
            if let reason = authority.verdict(BrowserReplAccess(.load(url))).reason {
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

    /// `page.clipboard` reads the tab's clipboard, which only the session
    /// that created the tab holds (``BrowserReplTabClipboard``).
    @MainActor
    private func readClipboard(_ params: [String: Any]) throws -> [String: Any] {
        guard let items = attachment(try panel(params)).clipboard.read(by: sessionID) else {
            throw Self.clipboardRefusedInUserTab()
        }
        return ["items": items]
    }

    @MainActor
    private func writeClipboard(_ params: [String: Any]) throws -> Any? {
        let items = params["items"] as? [[String: Any]] ?? []
        guard attachment(try panel(params)).clipboard.write(items, by: sessionID) else {
            throw Self.clipboardRefusedInUserTab()
        }
        return nil
    }

    /// A user's tab (one no attached session created, also one a finished
    /// run kept) has no tab clipboard for sessions: two sessions driving it
    /// would pass bytes to each other through it.
    private static func clipboardRefusedInUserTab() -> BrowserReplDriverError {
        error(
            "unsupported",
            "page.clipboard is refused in a user's tab (one no attached session opened): a tab's clipboard belongs to the session that opened the tab, and other sessions may drive a user's tab. Open the page with tabs.open() to use it"
        )
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

/// Hands a call's cancellation to a task it runs work in that does not
/// inherit it (the render host's): the work is cancelled when the call is,
/// also when the call was cancelled before the work began.
private final class BrowserReplCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancelWork: (@Sendable () -> Void)?

    /// Cancels through `cancel` when the call is cancelled, at once if it already is.
    func bind(_ cancel: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            if cancelled { return true }
            cancelWork = cancel
            return false
        }
        if now { cancel() }
    }

    func cancel() {
        let work: (@Sendable () -> Void)? = lock.withLock {
            cancelled = true
            defer { cancelWork = nil }
            return cancelWork
        }
        work?()
    }
}
