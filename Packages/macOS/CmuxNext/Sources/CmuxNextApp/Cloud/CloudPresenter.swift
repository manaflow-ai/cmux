import AppKit
import CmuxNextDesign

/// cmux dialogs for Cloud prompts and results, on the active window; with
/// no window a result is only logged and a question answers cancel.
enum CloudPresenter {
    /// Shows a result; `copyable` text gets a Copy button.
    static func show(_ title: String, _ body: String, copyable: Bool = false, in window: NSWindow?) {
        var buttons: [CmuxDialogButton] = []
        if copyable { buttons.append(CmuxDialogButton(id: "copy", title: CloudStrings.copy)) }
        buttons.append(CmuxDialogButton(id: "ok", title: CloudStrings.ok, role: .default))
        let spec = CmuxDialogSpec(title: title, lines: [body], buttons: buttons, identifier: "cmux.dialog.cloud.result")
        present(spec, in: window) { answer in
            if answer?.button == "copy" { copy(body) }
        }
    }

    static func failure(_ error: any Error, in window: NSWindow?) {
        show(CloudStrings.failedTitle, String(describing: error), in: window)
    }

    /// Asks for a line of text. Calls `done` with the text, or nil on cancel.
    static func askText(_ title: String, initial: String, button: String, in window: NSWindow?, done: @escaping (String?) -> Void) {
        let spec = CmuxDialogSpec(title: title, fields: [.text("text", initial: initial)],
                                  buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "confirm", title: button, role: .default)],
                                  identifier: "cmux.dialog.cloud.text")
        present(spec, in: window) { answer in
            done(answer?.button == "confirm" ? answer?.text("text") : nil)
        }
    }

    /// Asks to pick one of `choices` (title, value).
    static func choose(_ title: String, _ choices: [(String, String)], selected: String?, in window: NSWindow?, done: @escaping (String?) -> Void) {
        let options = choices.map { CmuxDialogOption(label: $0.0, value: $0.1) }
        let spec = CmuxDialogSpec(title: title, fields: [.choice(id: "choice", label: nil, options: options, selected: selected)],
                                  buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "select", title: CloudStrings.select, role: .default)],
                                  identifier: "cmux.dialog.cloud.choose")
        present(spec, in: window) { answer in
            done(answer?.button == "select" ? answer?.text("choice") : nil)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// nil when there is no window to ask in.
    private static func present(_ spec: CmuxDialogSpec, in window: NSWindow?, done: @escaping (CmuxDialogAnswer?) -> Void) {
        guard let window else { return done(nil) }
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { done($0) }
    }
}
