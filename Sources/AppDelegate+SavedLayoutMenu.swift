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
        guard let tabManager = activeTabManagerForCommands(
            preferredWindow: preferredWindow ?? shortcutRoutingActiveWindow
        ) else {
            NSSound.beep()
            return
        }
        presentSavedLayoutSavePrompt(tabManager: tabManager)
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

    private func presentSavedLayoutSavePrompt(tabManager: TabManager) {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.savedLayout.save.title",
            defaultValue: "Save Layout as Template"
        )
        alert.informativeText = String(
            localized: "dialog.savedLayout.save.message",
            defaultValue: "Enter a name for this workspace layout."
        )
        alert.addButton(withTitle: String(
            localized: "dialog.savedLayout.save.confirm",
            defaultValue: "Save"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = String(
            localized: "dialog.savedLayout.save.placeholder",
            defaultValue: "Layout name"
        )
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runCmuxModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentSavedLayoutError(message: String(
                localized: "dialog.savedLayout.error.blankName",
                defaultValue: "Enter a name before saving the layout."
            ))
            return
        }

        let store = SavedLayoutStore()
        let existingLayout: CmuxSavedLayout?
        do {
            existingLayout = try store.layout(named: name)
        } catch {
            presentSavedLayoutError(message: savedLayoutErrorMessage(error))
            return
        }
        let overwrite = existingLayout == nil || confirmSavedLayoutOverwrite(name: name)
        guard overwrite else { return }

        do {
            let capture = try workspace.captureLayoutDefinition()
            try store.save(
                CmuxSavedLayout(name: name, description: nil, workspace: capture.workspace),
                overwrite: existingLayout != nil
            )
        } catch {
            presentSavedLayoutError(message: savedLayoutErrorMessage(error))
        }
    }

    private func confirmSavedLayoutOverwrite(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.savedLayout.overwrite.title",
            defaultValue: "Replace Saved Layout?"
        )
        let format = String(
            localized: "dialog.savedLayout.overwrite.message",
            defaultValue: "A layout named “%@” already exists. Replace it?"
        )
        alert.informativeText = String.localizedStringWithFormat(format, name)
        alert.addButton(withTitle: String(
            localized: "dialog.savedLayout.overwrite.confirm",
            defaultValue: "Replace"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runCmuxModal() == .alertFirstButtonReturn
    }

    private func presentSavedLayoutError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.savedLayout.error.title",
            defaultValue: "Layout Not Saved"
        )
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal()
    }

    private func savedLayoutErrorMessage(_ error: Error) -> String {
        if let storeError = error as? SavedLayoutStoreError {
            switch storeError {
            case .blankName:
                return String(
                    localized: "dialog.savedLayout.error.blankName",
                    defaultValue: "Enter a name before saving the layout."
                )
            case .duplicateName:
                return String(
                    localized: "dialog.savedLayout.error.duplicateName",
                    defaultValue: "A layout with that name already exists."
                )
            case .notFound:
                return String(
                    localized: "dialog.savedLayout.error.notFound",
                    defaultValue: "That saved layout could not be found."
                )
            case .corruptFile:
                return String(
                    localized: "dialog.savedLayout.error.corruptFile",
                    defaultValue: "The saved layouts file could not be read. Check it and try again."
                )
            }
        }
        return String(
            localized: "dialog.savedLayout.error.unknown",
            defaultValue: "The saved layout request could not be completed. Try again."
        )
    }
}
