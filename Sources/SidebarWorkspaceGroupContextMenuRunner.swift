import AppKit
import Foundation

/// Runs cwd-driven context-menu items from a sidebar group header.
@MainActor
enum SidebarWorkspaceGroupContextMenuRunner {
    static func run(
        item: CmuxResolvedConfigMenuAction,
        tabManager: TabManager,
        groupId: UUID
    ) {
        guard let appDelegate = AppDelegate.shared else { return }
        let didRun = appDelegate.runWorkspaceGroupConfiguredAction(
            item.action,
            tabManager: tabManager,
            groupId: groupId
        )
        // A copy action reports false without a beep when no terminal is
        // focused, so its shortcut can pass the keystroke through. A menu
        // pick still needs feedback.
        if !didRun,
           case .builtIn(let builtIn) = item.action.action,
           builtIn.terminalCopyAction != nil {
            NSSound.beep()
        }
    }
}
