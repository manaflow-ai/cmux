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

    func savedLayoutNewWorkspaceMenuItem(layoutNames: [String], windowId: UUID) -> NSMenuItem? {
        guard !layoutNames.isEmpty else { return nil }
        let parent = NSMenuItem(
            title: String(localized: "menu.savedLayout.newWorkspaceFromLayout", defaultValue: "New Workspace from Template"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for layoutName in layoutNames {
            let item = NSMenuItem(
                title: layoutName,
                action: #selector(performSavedLayoutContextMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = SavedLayoutContextMenuActionBox(windowId: windowId, layoutName: layoutName)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
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
            if context.tabManager.openWorkspace(fromSavedLayout: layout, cwdOverride: nil, focus: true) == nil {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
    }
}
