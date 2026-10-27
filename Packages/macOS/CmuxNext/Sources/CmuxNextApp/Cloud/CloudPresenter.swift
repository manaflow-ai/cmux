import AppKit
import CmuxNextDesign
import os

/// Cloud results as toasts and Cloud questions as cmux dialogs, on the
/// active window (Lawrence 2026-10-07: results are toasts, never dialogs);
/// with no window a result is only logged and a question answers cancel.
enum CloudPresenter {
    static let resultToastID = "cloud-result"

    /// Shows a result as a toast: the title and the body's first line (the
    /// whole body when it is one short line). `copyable` text gets a Copy
    /// action that copies the whole body, and the toast stays 12 s.
    static func show(_ title: String, _ body: String, copyable: Bool = false, in window: NSWindow?) {
        guard let window else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info("cloud result with no window: \(title, privacy: .public)")
            return
        }
        let message = body.isEmpty ? title : CloudStrings.result(title, summary(body))
        let toast = CmuxToast(id: resultToastID, message: message, action: copyable ? CmuxToast.Action(title: CloudStrings.copy) : nil,
                              duration: .seconds(copyable ? 12 : 6))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { copy(body) }
    }

    /// Shows a report as a toast: the title and `summary`, with a Copy
    /// details action that copies `details` (the raw report) and only on a
    /// click; the toast stays 12 s.
    static func show(_ title: String, summary: String, details: String, in window: NSWindow?) {
        guard let window else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info("cloud result with no window: \(title, privacy: .public)")
            return
        }
        let toast = CmuxToast(id: resultToastID, message: CloudStrings.result(title, summary),
                              action: CmuxToast.Action(title: CloudStrings.copyDetails), duration: .seconds(12))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { copy(details) }
    }

    /// One short line: the body itself, else its first non-empty line with "…".
    static func summary(_ body: String, limit: Int = 120) -> String {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return body }
        if lines.count == 1, first.count <= limit { return first }
        return String(first.prefix(limit)) + "…"
    }

    /// An error, copyable (the whole text goes to the clipboard on Copy).
    static func failure(_ error: any Error, in window: NSWindow?) {
        show(CloudStrings.failedTitle, CloudStrings.errorText(error), copyable: true, in: window)
    }

    /// The money confirmation of a machine create: only the person answers
    /// it (`DebugDialog.userOnly`), so automation can never approve a spend.
    static let createConfirmIdentifier = "cmux.dialog.cloud.createConfirm"

    /// Asks a yes/no question; `done(true)` only for a click on `button`.
    static func confirm(_ title: String, _ body: String, button: String, identifier: String = "cmux.dialog.cloud.confirm",
                        in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let spec = CmuxDialogSpec(title: title, lines: [body],
                                  buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "confirm", title: button, role: .default)],
                                  identifier: identifier)
        present(spec, in: window) { answer in done(answer?.button == "confirm") }
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
