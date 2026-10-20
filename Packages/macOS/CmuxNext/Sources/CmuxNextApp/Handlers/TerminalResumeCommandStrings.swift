import Foundation

/// Refusals and prompt text of Set, Edit and Clear Resume Command.
enum TerminalResumeCommandStrings {
    static var none: String {
        String(localized: "terminal.resumeCommand.none", defaultValue: "This terminal has no resume command.", table: "Handlers", bundle: .module)
    }
    static var needsCommand: String {
        String(localized: "terminal.resumeCommand.needsCommand", defaultValue: "Give the resume command with --arg command=…", table: "Handlers", bundle: .module)
    }
    static var save: String {
        String(localized: "terminal.resumeCommand.save", defaultValue: "Save", table: "Handlers", bundle: .module)
    }
}
