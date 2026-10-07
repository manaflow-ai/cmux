import AppKit
import CmuxNextDesign

/// A cmux dialog with one text field, for renames that have no inline editor.
enum RenamePrompt {
    static func spec(title: String, initial: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: title, fields: [.text("name", initial: initial)],
                       buttons: [.cancel(Strings.cancel), CmuxDialogButton(id: "rename", title: Strings.renameConfirm, role: .default)],
                       identifier: "cmux.dialog.rename")
    }

    static func run(title: String, initial: String, in window: NSWindow, completion: @escaping (String) -> Void) {
        CmuxDialogCenter.shared.present(spec(title: title, initial: initial), in: .window(window)) { answer in
            let name = answer.text("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard answer.button == "rename", !name.isEmpty else { return }
            completion(name)
        }
    }
}
