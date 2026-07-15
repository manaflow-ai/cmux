import CMUXMobileCore
import CmuxPanes
import Foundation

extension Workspace {
    /// Projects the authoritative Bonsplit state into the shared mobile DTO.
    func mobileWorkspaceLayout() -> MobileWorkspaceLayout {
        var tabsBySurfaceID: [String: MobileWorkspaceTab] = [:]
        for paneID in bonsplitController.allPaneIds {
            for tab in bonsplitController.tabs(inPane: paneID) {
                guard let panelID = panelIdFromSurfaceId(tab.id),
                      let panel = panels[panelID],
                      let kind = mobileWorkspaceTabKind(for: panel) else {
                    continue
                }
                tabsBySurfaceID[tab.id.uuid.uuidString] = MobileWorkspaceTab(
                    id: panelID.uuidString,
                    name: panelTitle(panelId: panelID) ?? panel.displayTitle,
                    kind: kind,
                    isActive: false,
                    isReady: mobileWorkspaceTabIsReady(panel),
                    agentStatus: mobileWorkspaceAgentStatus(panelID: panelID),
                    hasUnread: tab.showsNotificationBadge
                )
            }
        }
        return MobileWorkspaceLayoutMapper().layout(
            workspaceID: id.uuidString,
            tree: bonsplitController.treeSnapshot(),
            activePaneID: bonsplitController.focusedPaneId?.id.uuidString,
            tabsBySurfaceID: tabsBySurfaceID
        )
    }

    /// Records a pane/tab topology mutation after Bonsplit has committed it.
    func recordMobileWorkspaceLayoutChange() {
        var terminatedObserverIDs: [UUID] = []
        for (id, continuation) in mobileLayoutChangeObservers {
            if case .terminated = continuation.yield(()) {
                terminatedObserverIDs.append(id)
            }
        }
        for id in terminatedObserverIDs {
            mobileLayoutChangeObservers[id] = nil
        }
    }

    /// Streams value-free layout invalidations to the mobile observer.
    func mobileWorkspaceLayoutChanges() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observerID = UUID()
            mobileLayoutChangeObservers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.mobileLayoutChangeObservers[observerID] = nil
                }
            }
        }
    }

    private func mobileWorkspaceTabKind(for panel: any Panel) -> MobileWorkspaceTabKind? {
        switch panel.panelType {
        case .terminal:
            return .terminal
        case .browser, .extensionBrowser:
            return .browser
        default:
            return nil
        }
    }

    private func mobileWorkspaceTabIsReady(_ panel: any Panel) -> Bool {
        if let terminal = panel as? TerminalPanel {
            return terminal.surface.surface != nil
        }
        if let browser = panel as? BrowserPanel {
            return !browser.isClosingWebViewLifecycle
        }
        return false
    }

    private func mobileWorkspaceAgentStatus(panelID: UUID) -> MobileWorkspaceAgentStatus? {
        let states = (agentLifecycleStatesByPanelId[panelID] ?? [:])
            .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0.key) }
            .map(\.value)
        guard !states.isEmpty else { return nil }
        if states.contains(.running) { return .running }
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.unknown) { return .unknown }
        return .idle
    }
}
