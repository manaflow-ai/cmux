import AppKit
import Bonsplit
import CmuxNestedTopology
import CmuxTerminal
import Foundation
import OSLog

/// Mirrors one Herdr workspace (session) into a dedicated cmux sidebar workspace.
///
/// Tabs come from ``RemoteHerdrSessionApply``; each Herdr tab becomes a
/// ``RemoteHerdrWindowMirrorHost`` with real ``TerminalPanel``s. Output is polled
/// via ``pane.read``; Ghostty input is forwarded with ``pane.send``.
@MainActor
final class RemoteHerdrSessionHost {
    let socketPath: String
    let sessionID: String
    private(set) var sessionName: String
    let client: HerdrNestedTopologyClient
    let attachmentID: UUID
    let hostStableSurfaceID: UUID

    private weak var tabManager: TabManager?
    weak var workspace: Workspace?
    var mirroredWorkspace: Workspace? { workspace }
    var mirroredWorkspaceId: UUID? { workspace?.id }

    private let defaultPanelIds: [UUID]
    private var defaultClosed = false
    private var previousTabIDs: [String] = []
    private var previousTitles: [String: String] = [:]
    private var panelIdByTab: [String: UUID] = [:]
    private var tabIdByPanel: [UUID: String] = [:]
    private var windowMirrorByTabId: [String: RemoteHerdrWindowMirrorHost] = [:]
    private var surfaceToPane: [UUID: String] = [:]
    private var paneRoute = RemoteHerdrPaneRoute(loggingEnabled: false)
    private var lastLayouts: [String: RemoteHerdrLayoutNode] = [:]
    private var eventTask: Task<Void, Never>?
    private var outputPollTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?
    private let applyQueue = RemoteHerdrSerialWorkQueue()
    private var snapshotRefreshPending = false
    private var isTornDown = false
    var nativeLive = false
    private var needsReseed = false

    /// Shared plugin associations file (title locks survive native→plugin handoff).
    private let associationStore = RemoteHerdrAssociationStore(
        directories: RemoteHerdrHandoff.stateDirectories()
    )

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteHerdrSession")

    init(
        socketPath: String,
        sessionID: String,
        sessionName: String,
        client: HerdrNestedTopologyClient,
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        tabManager: TabManager,
        workspace: Workspace
    ) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.client = client
        self.attachmentID = attachmentID
        self.hostStableSurfaceID = hostStableSurfaceID
        self.tabManager = tabManager
        self.workspace = workspace
        self.defaultPanelIds = Array(workspace.panels.keys)
        workspace.remoteHerdrSessionHost = self
    }

    /// First snapshot after attach: create tabs/panels and start event + poll loops.
    func applyInitialSnapshot(
        _ snapshot: NestedTopologySnapshot,
        layouts: [String: RemoteHerdrLayoutNode]
    ) async throws {
        lastLayouts = layouts
        applySession(snapshot: snapshot, layouts: layouts)
        startEventLoop()
        startOutputPollLoop()
    }

    func requestReseed() {
        needsReseed = true
    }

    /// Tear down mirrors and cancel loops. Never ``server.stop``.
    func detach(reason: String) {
        guard !isTornDown else { return }
        isTornDown = true
        _ = RemoteHerdrLifecycle.hostClosePolicy(reason)
        eventTask?.cancel()
        eventTask = nil
        outputPollTask?.cancel()
        outputPollTask = nil
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        snapshotRefreshPending = false
        surfaceToPane.removeAll()
        for (tabID, mirror) in windowMirrorByTabId {
            if let panelId = panelIdByTab[tabID] {
                removeSurfaceMappings(for: mirror)
                workspace?.setRemoteHerdrWindowMirror(nil, forPanelId: panelId)
            }
            mirror.teardown()
        }
        windowMirrorByTabId.removeAll()
        panelIdByTab.removeAll()
        tabIdByPanel.removeAll()
        if workspace?.remoteHerdrSessionHost === self {
            workspace?.remoteHerdrSessionHost = nil
        }
        workspace?.isRemoteHerdrMirror = false
        workspace = nil
        Self.logger.info("remote-herdr: detached session=\(self.sessionID, privacy: .public) reason=\(reason, privacy: .public)")
    }

    func paneSurfaceEntries() -> [[String: Any]] {
        var rows: [(String, String, String, Bool)] = []
        for (tabID, mirror) in windowMirrorByTabId {
            for (paneID, panel) in mirror.panelsByPaneId {
                let onScreen = Self.isOnScreen(panel)
                rows.append((tabID, paneID, panel.id.uuidString, onScreen))
            }
        }
        return RemoteHerdrControl.paneSurfaceEntries(rows)
    }

    func paneGrids() -> [[String: Any]] {
        windowMirrorByTabId.keys.sorted().compactMap { tabID in
            windowMirrorByTabId[tabID]?.paneGridsPayload()
        }
    }

    func statePayload() -> [String: Any] {
        [
            "socket": socketPath,
            "session": sessionID,
            "attached": true,
            "mirrored": true,
            "native_live": nativeLive,
            "window_count": windowMirrorByTabId.count,
            "window_ids": Array(windowMirrorByTabId.keys).sorted(),
            "workspace_id": mirroredWorkspaceId?.uuidString as Any,
            "server_stopped": false,
        ]
    }

    /// Whether `surfaceId` belongs to a pane panel owned by this session.
    func containsSurface(_ surfaceId: UUID) -> Bool {
        surfaceToPane[surfaceId] != nil
    }

    /// Herdr pane id for a Ghostty surface, if this session owns it.
    func paneID(forSurfaceId surfaceId: UUID) -> String? {
        surfaceToPane[surfaceId]
    }

    /// User split from a mirrored pane → `pane.split` (never a local Bonsplit split).
    @discardableResult
    func handleMirrorSplitRequested(
        surfaceId: UUID,
        vertical: Bool
    ) async -> Bool {
        guard let paneID = paneID(forSurfaceId: surfaceId) else { return false }
        let direction: RemoteHerdrSplitDirection = vertical ? .down : .right
        do {
            try await client.splitPane(paneID: paneID, direction: direction)
            return true
        } catch {
            Self.logger.error(
                "remote-herdr: pane.split failed pane=\(paneID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Paste a single-line path/text into the Herdr pane behind `surfaceId`.
    @discardableResult
    func pasteIntoMirror(surfaceId: UUID, text: String) async -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return false
        }
        guard let paneID = paneID(forSurfaceId: surfaceId) else { return false }
        return await applyQueue.enqueue(.send(paneID: paneID)) {
            await self.performSend(paneID: paneID, data: Data(text.utf8))
        }
    }

    // MARK: - Topology apply

    private func applySession(
        snapshot: NestedTopologySnapshot,
        layouts: [String: RemoteHerdrLayoutNode]
    ) {
        guard let workspace, !isTornDown else { return }
        let workspaceNodeID = snapshot.workspaces.first { $0.id.rawID == sessionID }?.id
        let filteredTabs = snapshot.tabs.filter { tab in
            if let workspaceNodeID {
                return tab.workspaceID == workspaceNodeID
            }
            return true
        }
        let filteredTabIDs = Set(filteredTabs.map(\.id))
        let filteredPanes = snapshot.panes.filter { filteredTabIDs.contains($0.tabID) }
        let filteredPaneIDs = Set(filteredPanes.map(\.id))
        let filteredSnapshot = NestedTopologySnapshot(
            encodingVersion: snapshot.encodingVersion,
            attachmentID: snapshot.attachmentID,
            hostStableSurfaceID: snapshot.hostStableSurfaceID,
            provider: snapshot.provider,
            workspaces: snapshot.workspaces.filter { $0.id.rawID == sessionID },
            tabs: filteredTabs,
            panes: filteredPanes,
            agents: snapshot.agents.filter { filteredPaneIDs.contains($0.paneID) },
            focus: snapshot.focus
        )
        let windows = RemoteHerdrSessionMirror.windows(
            from: filteredSnapshot,
            layouts: layouts
        )
        let reconcile = RemoteHerdrSessionMirror.reconcile(
            windows: windows,
            previousTabIDs: previousTabIDs
        )
        let titles = RemoteHerdrSessionApply.titlesByTabID(windows)
        let actions = RemoteHerdrSessionApply.actions(
            reconcile,
            titles: titles,
            previousTitles: previousTitles,
            defaultsOpen: !defaultClosed,
            focusTabID: filteredSnapshot.focus.tabID?.rawID
        )
        for action in actions {
            applySessionAction(action, windows: windows, in: workspace)
        }
        for window in windows {
            reconcileWindowMirror(window: window, in: workspace)
        }
        previousTabIDs = reconcile.orderedTabIDs
        previousTitles = titles
        lastLayouts = layouts
    }

    private func applySessionAction(
        _ action: RemoteHerdrSessionAction,
        windows: [RemoteHerdrWindow],
        in workspace: Workspace
    ) {
        switch action.op {
        case "create_tab":
            guard let tabID = action.tabID,
                  panelIdByTab[tabID] == nil,
                  windows.contains(where: { $0.tabID == tabID })
            else { return }
            guard let panel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: 0,
                title: action.title ?? tabID,
                focus: false,
                onInput: { _ in }
            ) else { return }
            panelIdByTab[tabID] = panel.id
            tabIdByPanel[panel.id] = tabID
        case "rename_tab":
            guard let tabID = action.tabID,
                  let panelId = panelIdByTab[tabID],
                  let title = action.title
            else { return }
            workspace.updateRemoteTmuxTabTitle(panelId: panelId, title: title)
            // Persist title lock so plugin sync does not thrash after detach.
            lockAssociationTitle(paneOrTabID: tabID, title: title)
            if let rootPane = windowMirrorByTabId[tabID]?.activePaneID
                ?? windowMirrorByTabId[tabID]?.panelsByPaneId.keys.sorted().first
            {
                lockAssociationTitle(paneOrTabID: rootPane, title: title)
            }
        case "close_tab":
            guard let tabID = action.tabID,
                  let panelId = panelIdByTab[tabID]
            else { return }
            if let mirror = windowMirrorByTabId.removeValue(forKey: tabID) {
                removeSurfaceMappings(for: mirror)
                workspace.setRemoteHerdrWindowMirror(nil, forPanelId: panelId)
                mirror.teardown()
            }
            _ = workspace.removeRemoteTmuxDisplayPane(panelId)
            panelIdByTab.removeValue(forKey: tabID)
            tabIdByPanel.removeValue(forKey: panelId)
        case "close_default_tabs":
            closeDefaultTabsIfNeeded(in: workspace)
        case "reorder_tabs":
            let desired = action.orderedTabIDs.compactMap { panelIdByTab[$0] }
            if desired.count > 1 {
                _ = workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: desired)
            }
        case "focus_tab":
            guard let tabID = action.tabID,
                  let panelId = panelIdByTab[tabID]
            else { return }
            workspace.focusPanel(panelId)
        default:
            break
        }
    }

    private func reconcileWindowMirror(window: RemoteHerdrWindow, in workspace: Workspace) {
        guard let panelId = panelIdByTab[window.tabID] else { return }
        if let mirror = windowMirrorByTabId[window.tabID] {
            mirror.apply(window: window)
            syncSurfaceToPane(from: mirror)
            return
        }
        let mirror = RemoteHerdrWindowMirrorHost(
            tabID: window.tabID,
            panelId: panelId,
            appearance: workspace.bonsplitController.configuration.appearance,
            workspaceBonsplitController: workspace.bonsplitController,
            paneIO: client,
            makePanel: { [weak self, weak workspace] paneID in
                guard let self, let workspace else { return nil }
                return workspace.makeRemoteTmuxPanePanel(
                    onInput: { [weak self] input in
                        Task { @MainActor in
                            self?.forwardInput(input, toPane: paneID)
                        }
                    },
                    keyNameResolver: { nil }
                )
            }
        )
        mirror.onClosePaneRequest = { [weak self] paneID in
            Task { @MainActor in
                await self?.closePane(paneID)
            }
        }
        mirror.onFocusPaneRequest = { [weak self] paneID in
            Task { @MainActor in
                await self?.focusPane(paneID)
            }
        }
        mirror.onSplitPaneRequest = { [weak self] paneID, vertical in
            Task { @MainActor in
                await self?.splitPane(paneID, vertical: vertical)
            }
        }
        mirror.onResizePaneRequest = { [weak self] paneID, cols, rows in
            Task { @MainActor in
                await self?.resizePane(paneID, cols: cols, rows: rows)
            }
        }
        mirror.onSendInputRequest = { [weak self] paneID, text in
            self?.forwardInput(.bytes(Data(text.utf8)), toPane: paneID)
        }
        mirror.observeWorkspaceBonsplitConfiguration()
        mirror.apply(window: window)
        windowMirrorByTabId[window.tabID] = mirror
        syncSurfaceToPane(from: mirror)
        workspace.setRemoteHerdrWindowMirror(mirror, forPanelId: panelId)
        // Retire container terminal once inner panes exist.
        if !mirror.panelsByPaneId.isEmpty,
           let panel = workspace.panels[panelId] as? TerminalPanel {
            GhosttyApp.terminalSurfaceRegistry.unregister(panel.surface)
            panel.close()
        }
    }

    private func closePane(_ paneID: String) async {
        do {
            try await client.closePane(paneID: paneID)
        } catch {
            Self.logger.error(
                "remote-herdr: pane.close failed pane=\(paneID, privacy: .public)"
            )
        }
    }

    private func focusPane(_ paneID: String) async {
        do {
            guard let handshake = await client.currentHandshake() else { return }
            try await client.focus(
                nodeID: NestedNodeID(
                    providerKind: .herdr,
                    providerInstanceID: handshake.providerInstanceID,
                    kind: .pane,
                    rawID: paneID
                )
            )
        } catch {
            Self.logger.debug("remote-herdr: pane.focus failed")
        }
    }

    private func splitPane(_ paneID: String, vertical: Bool) async {
        let direction: RemoteHerdrSplitDirection = vertical ? .down : .right
        do {
            try await client.splitPane(paneID: paneID, direction: direction)
        } catch {
            Self.logger.error(
                "remote-herdr: pane.split failed pane=\(paneID, privacy: .public)"
            )
        }
    }

    private func resizePane(_ paneID: String, cols: Int, rows: Int) async {
        do {
            try await client.resizePane(paneID: paneID, cols: cols, rows: rows)
        } catch {
            Self.logger.debug("remote-herdr: pane.resize failed")
        }
    }

    private func closeDefaultTabsIfNeeded(in workspace: Workspace) {
        guard !defaultClosed, !panelIdByTab.isEmpty else { return }
        for panelId in defaultPanelIds {
            _ = workspace.removeRemoteTmuxDisplayPane(panelId)
        }
        defaultClosed = true
    }

    // MARK: - Input / output

    private func forwardInput(_ input: TerminalManualInput, toPane paneID: String) {
        guard !isTornDown else { return }
        let data: Data
        switch input {
        case .bytes(let bytes):
            data = bytes
        case .namedKey(let name):
            if let encoded = RemoteHerdrControl.encodeNamedKey(paneID: paneID, rawName: name),
               let csi = encoded.csi {
                data = csi
            } else if let encoded = RemoteHerdrControl.encodeNamedKey(paneID: paneID, rawName: name),
                      let text = encoded.text {
                data = Data(text.utf8)
            } else {
                return
            }
        }
        forwardBytes(data, toPane: paneID)
    }

    private func forwardBytes(_ data: Data, toPane paneID: String) {
        guard !isTornDown else { return }
        guard paneRoute.routeInput(paneID: paneID, data: data) != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.applyQueue.enqueue(.send(paneID: paneID)) {
                _ = await self.performSend(paneID: paneID, data: data)
            }
        }
    }

    private func routeOutput(paneID: String, text: String) {
        for mirror in windowMirrorByTabId.values where mirror.panelsByPaneId[paneID] != nil {
            if let write = paneRoute.routeOutputText(paneID: paneID, current: text) {
                mirror.deliverOutput(paneID: paneID, data: write.data, fullRedraw: write.fullRedraw)
            }
            return
        }
    }

    // MARK: - Loops

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.client.events() {
                    if Task.isCancelled { break }
                    await self.handleEvent(event)
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("remote-herdr: event loop ended")
            }
        }
    }

    private func handleEvent(_ event: NestedTopologyEvent) async {
        guard !isTornDown else { return }
        switch event {
        case .replaceSnapshot(let snapshot):
            await applyQueue.enqueue(.snapshot) {
                await self.applyReplaceSnapshot(snapshot)
            }
        case .focusChanged(let focus):
            if let paneID = focus.paneID?.rawID {
                for mirror in windowMirrorByTabId.values {
                    mirror.noteRemoteActivePane(paneID)
                }
            }
        case .titleUpdated(let id, let title):
            if id.kind == .tab, let panelId = panelIdByTab[id.rawID] {
                workspace?.updateRemoteTmuxTabTitle(panelId: panelId, title: title)
            }
            lockAssociationTitle(paneOrTabID: id.rawID, title: title)
            if id.kind == .tab,
               let rootPane = windowMirrorByTabId[id.rawID]?.activePaneID
                ?? windowMirrorByTabId[id.rawID]?.panelsByPaneId.keys.sorted().first
            {
                lockAssociationTitle(paneOrTabID: rootPane, title: title)
            }
        case .tabUpserted, .tabClosed, .paneUpserted, .paneClosed,
             .workspaceUpserted, .workspaceClosed, .agentUpserted, .agentClosed,
             .agentStatusUpdated:
            // Coalesce structural churn into a fresh snapshot.
            scheduleSnapshotRefresh()
        }
    }

    private func scheduleSnapshotRefresh() {
        if snapshotRefreshTask != nil {
            snapshotRefreshPending = true
            return
        }
        snapshotRefreshTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self else { return }
                    self.snapshotRefreshTask = nil
                    if self.snapshotRefreshPending {
                        self.snapshotRefreshPending = false
                        self.scheduleSnapshotRefresh()
                    }
                }
            }
            await self?.refreshFromSnapshot()
        }
    }

    private func performSend(paneID: String, data: Data) async -> Bool {
        guard !isTornDown else { return false }
        do {
            try await client.sendKeys(paneID: paneID, data: data)
            return true
        } catch {
            Self.logger.debug("remote-herdr: pane.send failed")
            return false
        }
    }

    private func applyReplaceSnapshot(_ snapshot: NestedTopologySnapshot) async {
        guard !isTornDown else { return }
        do {
            let layouts = try await client.snapshotWithLayouts().layouts
            applySession(snapshot: snapshot, layouts: layouts)
        } catch {
            applySession(snapshot: snapshot, layouts: lastLayouts)
        }
    }

    private func refreshFromSnapshot() async {
        guard !isTornDown else { return }
        await applyQueue.enqueue(.snapshot) {
            await self.performRefreshFromSnapshot()
        }
    }

    private func performRefreshFromSnapshot() async {
        guard !isTornDown else { return }
        do {
            let (snapshot, layouts) = try await client.snapshotWithLayouts()
            applySession(snapshot: snapshot, layouts: layouts)
        } catch {
            Self.logger.debug("remote-herdr: refresh snapshot failed")
        }
    }

    private func startOutputPollLoop() {
        outputPollTask?.cancel()
        outputPollTask = Task { [weak self] in
            // Herdr exposes no %output / streaming read event. Until the provider
            // grows one, this bounded poll (150ms busy / 500ms idle, 200 lines per
            // pane) is the delivery path. Cost scales with live pane count.
            var idlePolls = 0
            while !Task.isCancelled {
                guard let self, !self.isTornDown else { break }
                let paneIDs = await MainActor.run { self.pollablePaneIDs() }
                var readAny = false
                for paneID in paneIDs {
                    if Task.isCancelled { break }
                    do {
                        let data = try await self.client.readPane(paneID: paneID, lines: 200)
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            readAny = true
                            await MainActor.run {
                                self.ensurePaneBound(paneID)
                                self.routeOutput(paneID: paneID, text: text)
                            }
                        }
                    } catch {
                        // Capability absent or transient — keep polling.
                    }
                }
                if await MainActor.run(body: { self.needsReseed }) {
                    await MainActor.run { self.needsReseed = false }
                    await self.refreshFromSnapshot()
                }
                if readAny {
                    idlePolls = 0
                } else {
                    idlePolls += 1
                }
                // Provider-gap fallback only: Herdr has no push output stream.
                let delayMs = idlePolls > 3 ? 500 : 150
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }
    }

    private func pollablePaneIDs() -> [String] {
        var ids: [String] = []
        for mirror in windowMirrorByTabId.values {
            for paneID in mirror.panelsByPaneId.keys where paneRoute.surfaces[paneID] != nil {
                ids.append(paneID)
            }
        }
        return ids.sorted()
    }

    private func syncSurfaceToPane(from mirror: RemoteHerdrWindowMirrorHost) {
        for (paneID, panel) in mirror.panelsByPaneId {
            surfaceToPane[panel.id] = paneID
            if paneRoute.surfaces[paneID] == nil {
                paneRoute.bind(paneID: paneID, surfaceID: panel.id.uuidString)
            }
        }
    }

    private func removeSurfaceMappings(for mirror: RemoteHerdrWindowMirrorHost) {
        for panel in mirror.panelsByPaneId.values {
            surfaceToPane.removeValue(forKey: panel.id)
        }
    }

    private func ensurePaneBound(_ paneID: String) {
        guard paneRoute.surfaces[paneID] == nil else { return }
        for mirror in windowMirrorByTabId.values {
            if let panel = mirror.panelsByPaneId[paneID] {
                paneRoute.bind(paneID: paneID, surfaceID: panel.id.uuidString)
                return
            }
        }
    }

    private static func isOnScreen(_ panel: TerminalPanel) -> Bool {
        let view = panel.hostedView
        return view.isVisibleInUI
            && !view.isHidden
            && view.superview != nil
            && view.window?.isVisible == true
    }

    /// Persist a native-title lock into the shared plugin associations file.
    private func lockAssociationTitle(paneOrTabID: String, title: String) {
        let fingerprint = hostStableSurfaceID.uuidString.lowercased()
        _ = associationStore.lockTitle(
            fingerprint: fingerprint,
            paneID: paneOrTabID,
            title: title,
            authority: NestedTitleAuthority.hostSurfacePolicy.rawValue
        )
    }
}
