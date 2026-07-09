import AppKit
import Foundation

extension TerminalController {
    nonisolated static func shouldSuppressSocketCommandActivation() -> Bool {
        !currentSocketCommandFocusAllowanceStack().isEmpty
    }

    nonisolated static func socketCommandAllowsInAppFocusMutations() -> Bool {
        allowsInAppFocusMutationsForActiveSocketCommand()
    }

    private nonisolated static func allowsInAppFocusMutationsForActiveSocketCommand() -> Bool {
        currentSocketCommandFocusAllowanceStack().last ?? false
    }

    func socketCommandAllowsInAppFocusMutations() -> Bool {
        Self.allowsInAppFocusMutationsForActiveSocketCommand()
    }

    func v2FocusAllowed(requested: Bool = true) -> Bool {
        requested && socketCommandAllowsInAppFocusMutations()
    }

    func v2MaybeFocusWindow(for tabManager: TabManager) {
        guard socketCommandAllowsInAppFocusMutations(),
              let windowId = v2ResolveWindowId(tabManager: tabManager) else { return }
        _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
        setActiveTabManager(tabManager)
    }

    func v2MaybeSelectWorkspace(_ tabManager: TabManager, workspace: Workspace) {
        guard socketCommandAllowsInAppFocusMutations() else { return }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }
}
