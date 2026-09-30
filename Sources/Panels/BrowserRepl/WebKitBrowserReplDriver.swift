import AppKit
import CmuxBrowser
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
        await Task { @MainActor in
            await self.dispatch(method: method, paramsJSON: paramsJSON)
        }.value
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {
        lock.withLock { sink = eventSink }
    }

    func detach() {
        lock.withLock { sink = nil }
        let sessionID = self.sessionID
        Task { @MainActor in
            BrowserReplTabAttachments.shared.detach(sessionID: sessionID)
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
        let params = BrowserReplJSON.object(paramsJSON)
        // Every call on a tab first waits until the tab renders like a focused
        // foreground page; input must not race WebKit's focus update.
        if let raw = params["targetId"] as? String, let id = UUID(uuidString: raw),
           let panel = try? reachablePanel(id) {
            let attachment = attach(panel)
            // WebKit signals the update; the bound only guards a web process
            // that goes away before answering.
            _ = await withTimeout(milliseconds: 2_000) { await attachment.renderingSettled() }
        }
        defer {
            // A pane that shows a mirror of this tab gets the page's new look.
            if let raw = params["targetId"] as? String, let id = UUID(uuidString: raw) {
                BrowserReplTabAttachments.shared.attachment(for: id)?.pageDidChange()
            }
        }
        do {
            let value = try await handle(method: method, params: params)
            if let raw = value as? BrowserReplRawJSON { return .success(raw.text) }
            guard let json = BrowserReplJSON.encode(value) else {
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
        case "tabs.open": return try await openTab(params)
        case "tabs.close": return try closeTab(params)
        case "tabs.activate", "tab.bringToFront": return try activateTab(params)
        case "tab.keep": return try keepTab(params)
        case "session.name": return try nameSession(params)
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
        case "cookies.clear": return try await clearCookies()
        case "clipboard.read": return try readClipboard(params)
        case "clipboard.write": return try writeClipboard(params)
        default:
            throw Self.error("unsupported", "Unsupported driver method \(method)")
        }
    }

    static func error(_ code: String, _ message: String) -> BrowserReplDriverError {
        BrowserReplDriverError(code: code, message: message)
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
        guard let raw = params["targetId"] as? String, let id = UUID(uuidString: raw) else {
            throw Self.error("invalid", "targetId is required")
        }
        guard let panel = try reachablePanel(id) else {
            throw Self.error("closed", "Tab \(raw) is closed")
        }
        attach(panel).keepRendering()
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
    /// `tabs.list({ all: true })` listed it (ChatGPT's claimTab).
    @MainActor
    private func reachablePanel(_ id: UUID) throws -> BrowserPanel? {
        if let own = try browserPanels().first(where: { $0.id == id }) { return own }
        return allBrowserPanels().first(where: { $0.panel.id == id })?.panel
    }

    @MainActor
    @discardableResult
    private func attach(_ panel: BrowserPanel) -> BrowserReplTabAttachment {
        BrowserReplTabAttachments.shared.attach(panel: panel, sessionID: sessionID) { [weak self] name, payload in
            self?.forward(name, payload)
        }
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
            if let uuid = UUID(uuidString: id) {
                openedTargetIDs.append(uuid)
                applySessionLabel(to: uuid)
            }
        }
        guard let json = BrowserReplJSON.encode(payload) else { return }
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
            let others: [[String: Any]] = allBrowserPanels()
                .filter { $0.workspace.id != workspace.id }
                .map { entry in
                    [
                        "targetId": entry.panel.id.uuidString,
                        "title": entry.panel.webView.title ?? entry.panel.pageTitle,
                        "url": entry.panel.webView.url?.absoluteString ?? entry.panel.currentURL?.absoluteString ?? "",
                        "active": false,
                        "windowId": entry.workspace.id.uuidString,
                    ]
                }
            return own + others
        }
        let active = activeTargetID.flatMap(UUID.init(uuidString:)).flatMap { id in panels.first { $0.id == id } }
            ?? panels.first { $0.id == workspace.focusedPanelId }
        return panels.map { panel in
            var entry: [String: Any] = [
                "targetId": panel.id.uuidString,
                "title": panel.webView.title ?? panel.pageTitle,
                "url": panel.webView.url?.absoluteString ?? panel.currentURL?.absoluteString ?? "",
                "active": panel.id == active?.id,
                "windowId": workspace.id.uuidString,
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
        let rawURL = params["url"] as? String
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
                  creationPolicy: .automationPreload
              ) else {
            throw Self.error("invalid", "Could not open a browser tab")
        }
        attach(panel)
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

    @MainActor
    private func closeTab(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
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

    /// `tab.keep`: the tab stays open after the session ends.
    @MainActor
    private func keepTab(_ params: [String: Any]) throws -> Any? {
        let panel = try panel(params)
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
        let ticket = panel.beginAutomationNavigation(to: url, recordTypedNavigation: false)
        let outcome = try await withTimeoutThrowing(milliseconds: timeout, what: "navigating to \"\(raw)\"") {
            await panel.finishAutomationNavigation(ticket)
        }
        try Self.check(outcome, url: raw)
        try await waitForLoadState(
            panel,
            Self.waitUntil(params),
            remainingMilliseconds: Self.remaining(timeout, since: started)
        )
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
        let ticket = panel.automationNavigationCoordinator.begin(
            instanceID: panel.webViewInstanceID,
            targetURL: item.url,
            allowsSameDocumentCompletion: true
        )
        let navigation = delta < 0 ? webView.goBack() : webView.goForward()
        panel.automationNavigationCoordinator.didStart(ticket, navigationID: navigation.map { ObjectIdentifier($0) })
        let outcome = try await withTimeoutThrowing(milliseconds: timeout, what: "navigating history") {
            await panel.finishAutomationNavigation(ticket)
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
        guard let (ticket, target) = panel.beginAutomationReloadFromCLI() else {
            throw Self.error("invalid", "Nothing to reload")
        }
        let outcome = try await withTimeoutThrowing(milliseconds: timeout, what: "reloading") {
            await panel.finishAutomationNavigation(ticket)
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
        result["url"] = webView.url?.absoluteString ?? panel.currentURL?.absoluteString ?? ""
        result["title"] = webView.title ?? panel.pageTitle
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
        let names = frames.map { frame in
            Task { @MainActor in
                (try? await webView.callAsyncJavaScript(
                    "return window.name;",
                    arguments: [:],
                    in: frame.info,
                    contentWorld: BrowserReplAgentWorld.world
                )) as? String
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
        _ = try await panel.webView.callAsyncJavaScript(listen, arguments: ["__key": key], in: frame.info, contentWorld: .page)
        let dispatch = Self.evaluationBody(
            source: "(...els) => { for (const el of els) el.dispatchEvent(new CustomEvent(__key, { bubbles: true, composed: true })); return els.length; }",
            requiresAgent: true,
            elementsExpression: "__handles.map((h) => __agent.element(h))"
        )
        do {
            _ = try await runEvaluation(
                panel,
                frame,
                body: "const __key = \(BrowserReplJSON.encode(key) ?? "\"\"");\n" + dispatch,
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
                value = try await panel.webView.callAsyncJavaScript(body, arguments: arguments, in: frame.info, contentWorld: world)
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
            let value = try await panel.webView.callAsyncJavaScript(
                script,
                arguments: ["__index": child.indexInParent],
                in: parent.info,
                contentWorld: BrowserReplAgentWorld.world
            )
            return value ?? NSNull()
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
        try await withWindow(panel) { [self] webView, _ in
            let result = webView.replayBrowserReplKeyStroke(stroke, keyDown: type == "down")
            guard result == .delivered else {
                throw Self.error("invalid", "Could not deliver key \"\(keyName)\"")
            }
            if type == "down", let command = stroke.editingCommand {
                try await self.performEditingCommand(command, panel: panel, webView: webView)
            }
            await BrowserReplNativeInput.roundTrip(webView)
        }
        return nil
    }

    /// Runs the Cocoa editing action behind a Command shortcut. Clipboard
    /// actions use the tab's virtual clipboard, never the system pasteboard.
    @MainActor
    private func performEditingCommand(_ command: String, panel: BrowserPanel, webView: CmuxWebView) async throws {
        let attachment = attachment(panel)
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
        case "paste:":
            let text = attachment.clipboardItems
                .first { ($0["type"] as? String) == "text/plain" }
                .flatMap { ($0["base64"] as? String).flatMap { Data(base64Encoded: $0) } }
                .map { String(decoding: $0, as: UTF8.self) }
            if let text, !text.isEmpty {
                BrowserReplNativeInput.insertText(text, into: webView)
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
        try await withWindow(panel) { webView, _ in
            BrowserReplNativeInput.insertText(text, into: webView)
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
        return nil
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
        guard attachment(panel).respondToFileChooser(id: id, files: urls) else {
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
        guard attachment(panel).respondToDialog(id: id, accept: accept, promptText: params["promptText"] as? String) else {
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
        let image: CGImage = try await withWindow(panel) { webView, _ in
            try await BrowserReplCapture.snapshot(webView: webView, clip: clip, fullPage: fullPage)
        }
        let data = try BrowserReplCapture.encode(image, format: format, quality: quality)
        return ["base64": data.base64EncodedString(), "width": image.width, "height": image.height]
    }

    @MainActor
    private func pdf(_ params: [String: Any]) async throws -> [String: Any] {
        let panel = try panel(params)
        let data: Data = try await withWindow(panel) { [self] webView, _ in
            // Printing runs AppKit's print machinery; if it never reports
            // back, fall back to WebKit's single-page PDF.
            do {
                return try await self.withTimeoutThrowing(milliseconds: 20_000, what: "printing") {
                    try await BrowserReplCapture.printPDF(webView: webView, options: params)
                }
            } catch {
                return try await webView.pdf(configuration: WKPDFConfiguration())
            }
        }
        return ["base64": data.base64EncodedString()]
    }

    // MARK: - Browser state

    @MainActor
    private func cookieStore(_ params: [String: Any]) throws -> WKHTTPCookieStore {
        if params["targetId"] != nil {
            return try panel(params).webView.configuration.websiteDataStore.httpCookieStore
        }
        let panels = try browserPanels()
        let preferred = activeTargetID.flatMap(UUID.init(uuidString:)).flatMap { id in panels.first { $0.id == id } }
            ?? panels.first
        if let preferred {
            return preferred.webView.configuration.websiteDataStore.httpCookieStore
        }
        return BrowserProfileStore.shared
            .websiteDataStore(for: BrowserPanel.resolvedProfileID(requested: nil))
            .httpCookieStore
    }

    @MainActor
    private func cookies(_ params: [String: Any]) async throws -> [[String: Any]] {
        let store = try cookieStore(params)
        let all = await store.allCookies()
        let urls = (params["urls"] as? [String])?.compactMap(URL.init(string:)) ?? []
        let filtered = urls.isEmpty ? all : all.filter { cookie in
            urls.contains { BrowserReplCapture.cookie(cookie, matches: $0) }
        }
        return filtered.map(BrowserReplCookieCoding.json(from:))
    }

    @MainActor
    private func setCookies(_ params: [String: Any]) async throws -> Any? {
        let store = try cookieStore(params)
        for json in params["cookies"] as? [[String: Any]] ?? [] {
            guard let cookie = BrowserReplCookieCoding.cookie(from: json) else {
                throw Self.error("invalid", "Invalid cookie \(json["name"] as? String ?? "")")
            }
            await store.setCookie(cookie)
        }
        return nil
    }

    @MainActor
    private func clearCookies() async throws -> Any? {
        let store = try cookieStore([:])
        for cookie in await store.allCookies() {
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
