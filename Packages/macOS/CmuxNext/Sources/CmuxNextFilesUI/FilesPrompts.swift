import AppKit
import CmuxNextDesign
import CmuxNextFiles

/// The Files sheets: Go to Folder, the name-conflict question and rename for tiles.
@MainActor
struct FilesPrompts {
    /// The window the dialogs block.
    let window: () -> NSWindow?

    /// Asks for a path (Go to Folder). Nil when cancelled.
    func goToFolder(initial: String) async -> String? {
        let answer = await present(FilesDialogs.goToFolder(initial: initial))
        return answer.button == "ok" ? answer.text("name") ?? initial : nil
    }

    /// Asks for a new name (icon layout's Rename). Nil when cancelled.
    func rename(_ name: String) async -> String? {
        await textSheet(title: FilesStrings.rename, initial: name, button: FilesStrings.rename)
    }

    /// Asks what to do with a taken name (Keep Both, Stop, Replace, Skip, Apply to All).
    func conflict(_ conflict: FileConflict) async -> ConflictAnswer {
        let answer = await present(FilesDialogs.conflict(name: conflict.existing.lastPathComponent))
        let choice: ConflictChoice = switch answer.button {
        case "keepBoth": .keepBoth
        case "replace": .replace
        case "skip": .skip
        default: .stop
        }
        return ConflictAnswer(choice, applyToAll: answer.isOn("all"))
    }

    /// Rename Items… for several items. Nil when cancelled.
    func batchRename(_ names: [String]) async -> BatchRename? {
        let sheet = BatchRenameSheet(names: names)
        // dialog-keys-exempt: the live-example accessory (mode, fields, preview) has no CmuxDialogSpec field yet.
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
        await present(FilesDialogs.deleteImmediately(count: count)).button == "delete"
    }

    private func textSheet(title: String, initial: String, button: String) async -> String? {
        let answer = await present(FilesDialogs.text(title: title, initial: initial, button: button))
        return answer.button == "ok" ? answer.text("name") ?? initial : nil
    }

    private func present(_ spec: CmuxDialogSpec) async -> CmuxDialogAnswer {
        await CmuxDialogCenter.shared.present(spec, in: window().map(CmuxDialogScope.window) ?? .app)
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window() else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

/// The Files pane's cmux dialogs (u2647: every button shows its key), shared by
/// ``FilesPrompts`` and the app's `debug.dialog` fixtures, so a capture shows
/// exactly what the pane asks.
public enum FilesDialogs {
    /// A taken name: Stop (Esc), Skip (Cmd-S), Replace (Cmd-R), Keep Both (Return), Apply to All.
    public static func conflict(name: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: FilesStrings.conflict(name),
            fields: [.check(id: "all", title: FilesStrings.applyToAll, on: false)],
            buttons: [CmuxDialogButton(id: "stop", title: FilesStrings.stop, role: .cancel),
                      CmuxDialogButton(id: "skip", title: FilesStrings.skip, key: "s"),
                      CmuxDialogButton(id: "replace", title: FilesStrings.replace, role: .destructive, key: "r"),
                      CmuxDialogButton(id: "keepBoth", title: FilesStrings.keepBoth, role: .default)],
            identifier: "cmux.files.conflict")
    }

    /// Delete Immediately's confirmation: it cannot be undone.
    public static func deleteImmediately(count: Int) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: FilesStrings.deleteConfirm(count), lines: [FilesStrings.deleteCannotUndo],
            buttons: [.cancel(FilesStrings.cancel),
                      CmuxDialogButton(id: "delete", title: FilesStrings.delete, role: .destructive, key: "d")],
            identifier: "cmux.files.deleteImmediately")
    }

    /// One line of text: Go to Folder and Rename.
    public static func text(title: String, initial: String, button: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: title, fields: [.text("name", initial: initial)],
            buttons: [.cancel(FilesStrings.cancel), CmuxDialogButton(id: "ok", title: button, role: .default)],
            identifier: "cmux.files.text")
    }

    /// Go to Folder.
    public static func goToFolder(initial: String) -> CmuxDialogSpec {
        text(title: FilesStrings.goToTitle, initial: initial, button: FilesStrings.go)
    }
}
