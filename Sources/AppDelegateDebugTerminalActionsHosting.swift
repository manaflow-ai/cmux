#if DEBUG
import AppKit
import CmuxTestSupport
import CmuxWorkspaces
import Foundation

/// Live-state conformance for the Debug menu's terminal-tab openers.
///
/// ``DebugTerminalActionsCoordinator`` owns the opener orchestration (payload
/// selection, the React-vs-Solid renderer dispatch, and the color-comparison
/// create-or-reuse loop) in the `CmuxTestSupport` package. This extension
/// supplies the operations that touch live `TabManager` / `Workspace` /
/// terminal-surface state, which cannot cross the package boundary. The bodies
/// are a faithful lift of the former `AppDelegate` menu actions
/// (`openDebugScrollbackTab`, `openDebugLoremTab`, the private
/// `openDebugAgentSession(rendererKind:)`, and `openDebugColorComparisonWorkspaces`);
/// the coordinator addresses live workspaces only by their `UUID`, and the
/// mapping back to the real `Workspace` lives here.
extension AppDelegate: DebugTerminalActionsHosting {
    var canRunDebugTerminalActions: Bool {
        tabManager != nil
    }

    var ghosttyScrollbackLimit: Int {
        GhosttyConfig.load().scrollbackLimit
    }

    func addDebugTab() -> UUID? {
        tabManager?.addTab().id
    }

    func sendDebugText(_ text: String, toTab tabId: UUID) {
        guard let tab = tabManager?.tabs.first(where: { $0.id == tabId }) else { return }
        sendTextWhenReady(text, to: tab)
    }

    func openDebugAgentSession(rendererKind: DebugAgentSessionRendererKind) {
        let appRendererKind: AgentSessionRendererKind
        switch rendererKind {
        case .react:
            appRendererKind = .react
        case .solid:
            appRendererKind = .solid
        }
        guard let manager = activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        _ = workspace.newAgentSessionSurface(
            inPane: paneId,
            providerID: .codex,
            rendererKind: appRendererKind,
            workingDirectory: workspace.currentDirectory,
            focus: true
        )
    }

    func debugTabSnapshots() -> [DebugTerminalTabSnapshot] {
        guard let tabManager else { return [] }
        return tabManager.tabs.map { tab in
            DebugTerminalTabSnapshot(id: tab.id, customTitle: tab.customTitle)
        }
    }

    func setDebugTabCustomTitle(tabId: UUID, title: String) {
        _ = tabManager?.setCustomTitle(tabId: tabId, title: title)
    }

    func setDebugTabColor(tabId: UUID, hex: String) {
        tabManager?.setTabColor(tabId: tabId, color: hex)
    }

    func debugColorComparisonPalette() -> [DebugColorComparisonEntry] {
        WorkspaceTabColorSettings().palette().map { entry in
            DebugColorComparisonEntry(name: entry.name, hex: entry.hex)
        }
    }
}
#endif
