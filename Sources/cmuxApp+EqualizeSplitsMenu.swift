import AppKit
import SwiftUI

extension cmuxApp {
    func equalizeSplitsCommandButton() -> some View {
        splitCommandButton(title: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"), shortcut: menuShortcut(for: .equalizeSplits)) {
            if let dock = AppDelegate.shared?.focusedDockStoreForShortcut(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                _ = dock.performShortcutCommand(.equalizeSplits)
                return
            }
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
    func paneSizingCommandButtons() -> some View {
            equalizeSplitsCommandButton()
            splitCommandButton(
                title: KeyboardShortcutSettings.Action.resizePaneLeft.label,
                shortcut: menuShortcut(for: .resizePaneLeft)
            ) {
                _ = AppDelegate.shared?.performResizePaneShortcut(direction: .left)
            }
            splitCommandButton(
                title: KeyboardShortcutSettings.Action.resizePaneRight.label,
                shortcut: menuShortcut(for: .resizePaneRight)
            ) {
                _ = AppDelegate.shared?.performResizePaneShortcut(direction: .right)
            }
            splitCommandButton(
                title: KeyboardShortcutSettings.Action.resizePaneUp.label,
                shortcut: menuShortcut(for: .resizePaneUp)
            ) {
                _ = AppDelegate.shared?.performResizePaneShortcut(direction: .up)
            }
            splitCommandButton(
                title: KeyboardShortcutSettings.Action.resizePaneDown.label,
                shortcut: menuShortcut(for: .resizePaneDown)
            ) {
                _ = AppDelegate.shared?.performResizePaneShortcut(direction: .down)
            }
    }
}
