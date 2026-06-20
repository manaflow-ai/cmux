import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            updatedAt: effective.updatedAt
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }

        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]
        for paneId in ws.bonsplitController.allPaneIds {
            let tabs = ws.bonsplitController.tabs(inPane: paneId)
            let selected = ws.bonsplitController.selectedTab(inPane: paneId)
            for (idx, tab) in tabs.enumerated() {
                guard let panelId = ws.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = idx
                selectedInPaneByPanelId[panelId] = (tab.id == selected?.id)
            }
        }

        let focusedSurfaceId = ws.focusedPanelId
        let surfaces: [ControlSurfaceSummary] = orderedPanels(in: ws).map { panel in
            let terminalPanel = panel as? TerminalPanel
            return ControlSurfaceSummary(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                title: ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                isFocused: panel.id == focusedSurfaceId,
                paneID: paneByPanelId[panel.id],
                indexInPane: indexInPaneByPanelId[panel.id],
                selectedInPane: selectedInPaneByPanelId[panel.id],
                developerToolsVisible: (panel as? BrowserPanel)?.isDeveloperToolsVisible(),
                requestedWorkingDirectory: terminalPanel.flatMap {
                    v2NonEmptyString($0.requestedWorkingDirectory)
                },
                initialCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugInitialCommand())
                },
                tmuxStartCommand: terminalPanel.flatMap {
                    v2NonEmptyString($0.surface.debugTmuxStartCommand())
                },
                isTerminal: terminalPanel != nil,
                resumeBinding: terminalPanel != nil
                    ? controlResumeBinding(from: ws.surfaceResumeBinding(panelId: panel.id))
                    : nil
            )
        }

        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: surfaces
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }
        let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: paneId,
            surfaceID: surfaceId,
            surfaceTypeRawValue: surfaceId.flatMap { ws.panels[$0]?.panelType.rawValue }
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing),
              let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return nil
        }
        let items: [ControlSurfaceHealthEntry] = orderedPanels(in: ws).map { panel in
            var inWindow: Bool?
            var visibleInUI: Bool?
            if let tp = panel as? TerminalPanel {
                inWindow = tp.surface.isViewInWindow
                visibleInUI = inWindow == true
                    && tp.hostedView.debugPortalVisibleInUI
                    && !tp.hostedView.isHiddenOrHasHiddenAncestor
                    && tp.hostedView.bounds.width > 1
                    && tp.hostedView.bounds.height > 1
            } else if let bp = panel as? BrowserPanel {
                inWindow = bp.webView.window != nil
                visibleInUI = inWindow == true && bp.debugWebViewVisibleInUI
            }
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: inWindow,
                visibleInUI: visibleInUI
            )
        }
        let windowVisible = tabManager.window.map { window in
            window.isVisible && !window.isMiniaturized
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            windowVisible: windowVisible,
            surfaces: items
        )
    }

    func controlSurfaceWaitForInWindow(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) async -> Bool {
        if controlSurfaceIsVisibleInTargetUI(routing: routing, surfaceID: surfaceID) {
            return true
        }

        return await SurfaceHostedWindowWait(
            surfaceID: surfaceID,
            isVisible: { [weak self] in
                self?.controlSurfaceIsVisibleInTargetUI(routing: routing, surfaceID: surfaceID) == true
            }
        ).wait(
            timeout: .milliseconds(1_500)
        )
    }

    private func controlSurfaceIsVisibleInTargetUI(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> Bool {
        guard let health = controlSurfaceHealth(routing: routing),
              health.windowVisible == true,
              let entry = health.surfaces.first(where: { $0.surfaceID == surfaceID }) else {
            return false
        }
        return entry.visibleInUI == true
    }

    // MARK: - focus

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }
        guard ws.panels[surfaceID] != nil else {
            return .surfaceNotFound(surfaceID)
        }
        ws.focusPanel(surfaceID)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}

@MainActor
private final class SurfaceHostedWindowWait {
    private let surfaceID: UUID
    private let isVisible: @MainActor () -> Bool
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completed = false

    init(
        surfaceID: UUID,
        isVisible: @escaping @MainActor () -> Bool
    ) {
        self.surfaceID = surfaceID
        self.isVisible = isVisible
    }

    func wait(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: .surfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let hostedSurfaceID = notification.userInfo?["surfaceId"] as? UUID else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, hostedSurfaceID == self.surfaceID else { return }
                    guard self.isVisible() else { return }
                    self.complete(observed: true)
                }
            }
            timeoutTask = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return
                }
                await self?.complete(observed: false)
            }
        }
    }

    private func complete(observed: Bool) {
        guard !completed else { return }
        completed = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: observed)
    }
}
