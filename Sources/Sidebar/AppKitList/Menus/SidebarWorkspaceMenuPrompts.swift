import AppKit
import Foundation

/// NSAlert prompt flows for the workspace-row context menu, ported verbatim
/// from `TabItemView.promptRename()` / `promptCustomColor(targetIds:)` /
/// `showInvalidColorAlert(_:)` in `Sources/ContentView.swift`.
@MainActor
enum SidebarWorkspaceMenuPrompts {
    static func promptRename(
        snapshot: SidebarWorkspaceRowSnapshot,
        actions: SidebarWorkspaceRowActions
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: snapshot.customTitle ?? snapshot.workspace.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        // Focus after runModal presents the sheet window. RunLoop.perform
        // (not DispatchQueue.main.async) keeps the AppKit-list boundary free
        // of GCD scheduling per scripts/check-sidebar-lazy-layout.py.
        RunLoop.main.perform {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        actions.setCustomTitle(input.stringValue)
    }

    static func promptCustomColor(
        snapshot: SidebarWorkspaceRowSnapshot,
        actions: SidebarWorkspaceRowActions,
        targetIds: [UUID]
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = snapshot.workspace.customColorHex
            ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex
            ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        // Focus after runModal presents the sheet window. RunLoop.perform
        // (not DispatchQueue.main.async) keeps the AppKit-list boundary free
        // of GCD scheduling per scripts/check-sidebar-lazy-layout.py.
        RunLoop.main.perform {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        actions.applyColor(normalized, targetIds)
    }

    private static func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }
}
