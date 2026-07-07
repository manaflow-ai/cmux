import AppKit
import Foundation

// MARK: - Terminal right-click context menu: configured cmux.json actions
// (`terminalContextMenu: true`). Mirrors the plus-button context menu wiring
// in AppDelegate+NewWorkspaceContextMenu.swift: items carry a box with the
// window identity + resolved action, and execution funnels through the shared
// `executeConfiguredCmuxAction` path (same as palette and shortcuts).

@MainActor
private final class TerminalContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: CmuxResolvedConfigAction

    init(windowId: UUID, action: CmuxResolvedConfigAction) {
        self.windowId = windowId
        self.action = action
    }
}

extension AppDelegate {

    /// Appends the config actions that opted into the terminal context menu.
    /// Returns true when at least one item was appended (callers add their own
    /// trailing separator).
    @discardableResult
    func appendTerminalContextMenuConfigActions(to menu: NSMenu, anchorView: NSView) -> Bool {
        guard let context = contextForMainWindow(anchorView.window),
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        let actions = cmuxConfigStore.terminalContextMenuCustomActions()
        guard !actions.isEmpty else { return false }

        for action in actions {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performTerminalContextMenuConfigAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = TerminalContextMenuActionBox(
                windowId: context.windowId,
                action: action
            )
            item.toolTip = action.tooltip
            item.image = action.icon?.contextMenuImage(
                configSourcePath: action.iconSourcePath,
                globalConfigPath: cmuxConfigStore.globalConfigPath
            )
            menu.addItem(item)
        }
        return true
    }

    @objc private func performTerminalContextMenuConfigAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TerminalContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        guard executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }
}
