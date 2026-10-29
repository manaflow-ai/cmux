import AppKit
import CmuxNextDesign
import CmuxNextFiles
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        let spec = CmuxDialogSpec(
            title: FilesStrings.conflict(conflict.existing.lastPathComponent),
            fields: [.check(id: "applyToAll", title: FilesStrings.applyToAll, on: false)],
            buttons: [
                CmuxDialogButton(id: "keepBoth", title: FilesStrings.keepBoth, role: .default),
                CmuxDialogButton(id: "stop", title: FilesStrings.stop, role: .cancel),
                CmuxDialogButton(id: "replace", title: FilesStrings.replace, role: .destructive, key: "r"),
                CmuxDialogButton(id: "skip", title: FilesStrings.skip, key: "k"),
            ],
            identifier: "cmux.dialog.files.conflict"
        )
        let answer = await present(spec)
        let choice: ConflictChoice = switch answer.button {
        case "keepBoth": .keepBoth
        case "replace": .replace
        case "skip": .skip
        default: .stop
        }
        return ConflictAnswer(choice, applyToAll: !answer.isDismissal && answer.isOn("applyToAll"))
    }

    /// Rename Items… for several items. Nil when cancelled.
    func batchRename(_ names: [String]) async -> BatchRename? {
        let sheet = BatchRenameSheet(names: names)
        // dialog-keys-exempt: the batch-rename form switches its fields with the mode popup, which a CmuxDialogSpec cannot do yet
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
        let spec = CmuxDialogSpec(
            title: FilesStrings.deleteConfirm(count),
            lines: [FilesStrings.deleteCannotUndo],
            buttons: [
                .cancel(FilesStrings.cancel),
                CmuxDialogButton(id: "delete", title: FilesStrings.delete, role: .destructive, key: "d"),
            ],
            identifier: "cmux.dialog.files.delete"
        )
        return await present(spec).button == "delete"
    }

    private func textSheet(title: String, initial: String, button: String) async -> String? {
        let spec = CmuxDialogSpec(
            title: title,
            fields: [.text("text", initial: initial)],
            buttons: [.cancel(FilesStrings.cancel), .ok(button)],
            identifier: "cmux.dialog.files.text"
        )
        let answer = await present(spec)
        return answer.button == "ok" ? answer.text("text") ?? "" : nil
    }

    /// Shows `spec` as a cmux dialog on the Files window (the app when it has none).
    private func present(_ spec: CmuxDialogSpec) async -> CmuxDialogAnswer {
        await CmuxDialogCenter.shared.present(spec, in: window().map(CmuxDialogScope.window) ?? .app)
    }

    /// Shows `alert` as a sheet on the Files window. With no window there is nothing to attach it to, and
    /// no nested modal loop stands in for one: the answer is Cancel.
    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window() else { return .cancel }
        // A sheet that went away without an answer is Cancel too.
        return (try? await withOnceContinuation { (continuation: OnceContinuation<NSApplication.ModalResponse, OnceContinuationError>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }) ?? .cancel
    }
}
