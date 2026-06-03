import SwiftUI

extension cmuxApp {
    func equalizeSplitsCommandButton() -> some View {
        splitCommandButton(title: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"), shortcut: menuShortcut(for: .equalizeSplits)) {
            let manager = activeTabManager
            if let workspace = manager.selectedWorkspace {
                let didEqualize = manager.equalizeSplits(tabId: workspace.id)
#if DEBUG
                if !didEqualize {
                    cmuxDebugLog("menu.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
                }
#endif
            }
        }
    }

    @ViewBuilder
    func growPaneCommandButtons() -> some View {
        splitCommandButton(title: KeyboardShortcutSettings.Action.growPaneLeft.label, shortcut: menuShortcut(for: .growPaneLeft)) {
            _ = activeTabManager.resizeFocusedSplit(direction: .left)
        }

        splitCommandButton(title: KeyboardShortcutSettings.Action.growPaneRight.label, shortcut: menuShortcut(for: .growPaneRight)) {
            _ = activeTabManager.resizeFocusedSplit(direction: .right)
        }

        splitCommandButton(title: KeyboardShortcutSettings.Action.growPaneUp.label, shortcut: menuShortcut(for: .growPaneUp)) {
            _ = activeTabManager.resizeFocusedSplit(direction: .up)
        }

        splitCommandButton(title: KeyboardShortcutSettings.Action.growPaneDown.label, shortcut: menuShortcut(for: .growPaneDown)) {
            _ = activeTabManager.resizeFocusedSplit(direction: .down)
        }
    }
}
