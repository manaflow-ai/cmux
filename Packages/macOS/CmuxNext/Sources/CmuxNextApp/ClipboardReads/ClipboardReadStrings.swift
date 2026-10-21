import CmuxNextDesign
import Foundation

/// The clipboard-read dialog (Resources/ClipboardReads.xcstrings).
enum ClipboardReadStrings {
    static let allowID = "allow"
    static let denyID = "deny"

    static var title: String {
        String(localized: "clipboardRead.title", defaultValue: "Allow a program to read the clipboard?",
               table: "ClipboardReads", bundle: .module)
    }

    static func message(terminal: String, host: String) -> String {
        String(localized: "clipboardRead.message",
               defaultValue: "A program in “\(terminal)” on \(host) asked for the clipboard contents.",
               table: "ClipboardReads", bundle: .module)
    }

    static func unknownOriginMessage(terminal: String) -> String {
        String(localized: "clipboardRead.message.unknownOrigin",
               defaultValue: "A program in “\(terminal)” asked for the clipboard contents. Its origin could not be verified.",
               table: "ClipboardReads", bundle: .module)
    }

    static var thisMac: String {
        String(localized: "clipboardRead.host.thisMac", defaultValue: "this Mac", table: "ClipboardReads", bundle: .module)
    }

    static var otherMachine: String {
        String(localized: "clipboardRead.host.other", defaultValue: "another machine", table: "ClipboardReads", bundle: .module)
    }

    static var untitledTerminal: String {
        String(localized: "clipboardRead.terminal.untitled", defaultValue: "Terminal", table: "ClipboardReads", bundle: .module)
    }

    static var allow: String {
        String(localized: "clipboardRead.allow", defaultValue: "Allow", table: "ClipboardReads", bundle: .module)
    }

    static var deny: String {
        String(localized: "clipboardRead.deny", defaultValue: "Deny", table: "ClipboardReads", bundle: .module)
    }

    /// Deny on Escape. Allow has no key: a Return typed into the terminal
    /// as the dialog opens must never hand over the clipboard.
    static func spec(terminal: String, host: String?) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: title, lines: [host.map { message(terminal: terminal, host: $0) } ?? unknownOriginMessage(terminal: terminal)],
            buttons: [
                CmuxDialogButton(id: denyID, title: deny, role: .cancel),
                CmuxDialogButton(id: allowID, title: allow, role: .normal),
            ],
            identifier: identifier)
    }

    /// The dialog's accessibility identifier; automation may not press it.
    static let identifier = "cmux.dialog.terminalClipboardRead"
}
