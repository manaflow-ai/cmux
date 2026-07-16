import AppKit
import CmuxSettings

/// Builds the shortcut-discovery menu only when the native footer button opens.
@MainActor
final class SidebarAppKitShortcutMenuController {
    func present(relativeTo anchorView: NSView) {
        let menu = NSMenu(
            title: String(
                localized: "settings.section.keyboardShortcuts",
                defaultValue: "Keyboard Shortcuts"
            )
        )
        menu.autoenablesItems = false
        for action in KeyboardShortcutSettings.settingsVisibleActions {
            let stored = KeyboardShortcutSettings.shortcut(for: action)
            let shortcut = stored.isUnbound
                ? String(
                    localized: "shortcutDiscovery.unassigned",
                    defaultValue: "Unassigned"
                )
                : action.displayedShortcutString(for: stored)
            let item = NSMenuItem(
                title: "\(action.label)    \(shortcut)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 4),
            in: anchorView
        )
    }
}
