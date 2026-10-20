import AppKit
import CmuxNextFiles

/// The Files sheets: Go to Folder, the name-conflict question and rename for tiles.
@MainActor
struct FilesPrompts {
    /// The window the sheets attach to.
    let window: () -> NSWindow?

    /// Asks for a path (Go to Folder). Nil when cancelled.
    func goToFolder(initial: String) async -> String? {
        await textSheet(title: FilesStrings.goToTitle, initial: initial, button: FilesStrings.go)
    }

    /// Asks for a new name (icon layout's Rename). Nil when cancelled.
    func rename(_ name: String) async -> String? {
        await textSheet(title: FilesStrings.rename, initial: name, button: FilesStrings.rename)
    }

    /// Asks what to do with a taken name (Keep Both, Stop, Replace, Skip, Apply to All).
    func conflict(_ conflict: FileConflict) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.messageText = FilesStrings.conflict(conflict.existing.lastPathComponent)
        alert.addButton(withTitle: FilesStrings.keepBoth)
        alert.addButton(withTitle: FilesStrings.stop)
        alert.addButton(withTitle: FilesStrings.replace)
        alert.addButton(withTitle: FilesStrings.skip)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = FilesStrings.applyToAll
        let response = await run(alert)
        let choice: ConflictChoice = switch response {
        case .alertFirstButtonReturn: .keepBoth
        case .alertThirdButtonReturn: .replace
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1): .skip
        default: .stop
        }
        return ConflictAnswer(choice, applyToAll: alert.suppressionButton?.state == .on)
    }

    /// Rename Items… for several items. Nil when cancelled.
    func batchRename(_ names: [String]) async -> BatchRename? {
        let sheet = BatchRenameSheet(names: names)
        let alert = NSAlert()
        alert.messageText = FilesStrings.renameItemsTitle(names.count)
        alert.addButton(withTitle: FilesStrings.rename)
        alert.addButton(withTitle: FilesStrings.cancel)
        alert.accessoryView = sheet.accessory
        let response = await run(alert)
        return response == .alertFirstButtonReturn ? sheet.rename : nil
    }

    /// Delete Immediately asks first: it cannot be undone.
    func confirmDelete(_ count: Int) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = FilesStrings.deleteConfirm(count)
        alert.informativeText = FilesStrings.deleteCannotUndo
        alert.addButton(withTitle: FilesStrings.delete)
        alert.addButton(withTitle: FilesStrings.cancel)
        return await run(alert) == .alertFirstButtonReturn
    }

    private func textSheet(title: String, initial: String, button: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: FilesStrings.cancel)
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = await run(alert)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window() else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
