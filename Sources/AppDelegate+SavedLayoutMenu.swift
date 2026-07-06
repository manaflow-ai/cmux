import AppKit
import Foundation

@MainActor
extension AppDelegate {
    private final class SavedLayoutContextMenuActionBox: NSObject {
        let windowId: UUID
        let layoutName: String

        init(windowId: UUID, layoutName: String) {
            self.windowId = windowId
            self.layoutName = layoutName
        }
    }

    func requestSavedLayoutSave(preferredWindow: NSWindow? = nil) {
        NotificationCenter.default.post(
            name: .savedLayoutSaveRequested,
            object: preferredWindow ?? shortcutRoutingActiveWindow
        )
    }

    func handleSavedLayoutShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .saveLayoutTemplate) else {
            return false
        }
        requestSavedLayoutSave(preferredWindow: commandPaletteWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow)
        return true
    }

    func appendSavedLayoutMenuItems(to menu: NSMenu, windowId: UUID) {
        let layouts = (try? SavedLayoutStore().list()) ?? []
        guard !layouts.isEmpty else { return }

        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }

        let parent = NSMenuItem(
            title: String(localized: "menu.savedLayout.newWorkspaceFromLayout", defaultValue: "New Workspace from Layout"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for layout in layouts {
            let item = NSMenuItem(
                title: layout.name,
                action: #selector(performSavedLayoutContextMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = SavedLayoutContextMenuActionBox(windowId: windowId, layoutName: layout.name)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func performSavedLayoutContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SavedLayoutContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              resolvedWindow(for: context) != nil else {
            NSSound.beep()
            return
        }

        do {
            guard let layout = try SavedLayoutStore().layout(named: box.layoutName) else {
                NSSound.beep()
                return
            }
            _ = context.tabManager.openWorkspace(fromSavedLayout: layout, cwdOverride: nil, focus: true)
        } catch {
            NSSound.beep()
        }
    }
}
