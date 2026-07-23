import Foundation

/// The app-owned execution context for one resolved command-palette target.
///
/// The target IDs are immutable, while every accessor revalidates them against
/// the live model. Handlers capture this value explicitly instead of changing
/// `TabManager`/`Workspace` focus accessors through dynamically scoped state.
@MainActor
struct CommandPaletteActionContext {
    let target: CommandPaletteActionTarget
    let tabManager: TabManager
    let owningWindowID: UUID

    private func liveOwningWindowContext() -> AppDelegate.MainWindowContext? {
        guard target.windowID == owningWindowID,
              let appDelegate = AppDelegate.shared,
              let windowContext = appDelegate.liveMainWindowContextForAction(tabManager: tabManager),
              windowContext.windowId == target.windowID else {
            return nil
        }
        return windowContext
    }

    func workspace() -> Workspace? {
        guard liveOwningWindowContext() != nil,
              let workspaceID = target.workspaceID else {
            return nil
        }
        return tabManager.tabs.first(where: { $0.id == workspaceID })
    }

    func panel() -> (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = workspace(),
              let panelID = target.panelID,
              let panel = workspace.panels[panelID] else {
            return nil
        }
        return (workspace, panelID, panel)
    }

    var terminalPanel: TerminalPanel? {
        panel()?.panel as? TerminalPanel
    }

    var browserPanel: BrowserPanel? {
        panel()?.panel as? BrowserPanel
    }
}
