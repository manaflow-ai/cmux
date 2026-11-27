import Foundation

/// User-facing text for Chief's memory: the settings section, the memory
/// sheet and the transcript's "Chief will remember" row.
enum ChiefMemoryStrings {
    // MARK: Settings section

    static var sectionEmpty: String {
        String(localized: "chief.memory.section.empty", defaultValue: "Chief hasn’t remembered anything yet.")
    }
    static var showAll: String { String(localized: "chief.memory.section.showAll", defaultValue: "Show All…") }
    static var forget: String { String(localized: "chief.memory.forget", defaultValue: "Forget") }
    static func forgetHelp(_ fact: String) -> String {
        String(format: String(localized: "chief.memory.forget.help", defaultValue: "Forget “%@”"), fact)
    }
    static var forgetFailed: String {
        String(localized: "chief.memory.forgetFailed", defaultValue: "Chief couldn’t forget that. Try again.")
    }
    static var editFailed: String {
        String(localized: "chief.memory.editFailed", defaultValue: "Chief couldn’t update that note. Try again.")
    }

    // MARK: Sheet

    static var sheetTitle: String { String(localized: "chief.memory.sheet.title", defaultValue: "Chief’s Memory") }
    static var sidebarAboutYou: String { String(localized: "chief.memory.sheet.aboutYou", defaultValue: "About You") }
    static var sidebarInstructions: String {
        String(localized: "chief.memory.sheet.instructions", defaultValue: "Instructions")
    }
    static var sidebarNotes: String { String(localized: "chief.memory.sheet.notes", defaultValue: "Notes") }
    static var edit: String { String(localized: "chief.memory.sheet.edit", defaultValue: "Edit") }
    static var editNote: String { String(localized: "chief.memory.sheet.editNote", defaultValue: "Edit note") }
    static var saveNote: String { String(localized: "chief.memory.sheet.saveNote", defaultValue: "Save") }
    static var done: String { String(localized: "chief.memory.sheet.done", defaultValue: "Done") }
    static var close: String { String(localized: "chief.memory.sheet.close", defaultValue: "Close") }
    static var emptyDocument: String {
        String(localized: "chief.memory.sheet.emptyDocument", defaultValue: "Nothing here yet. Click Edit to write it.")
    }
    /// The empty notes pane: how a note gets there.
    static var emptyNotes: String {
        String(localized: "chief.memory.sheet.emptyNotesHint",
               defaultValue: "No notes yet. Ask Chief to remember something, like “Remember that I prefer Codex for backend work.”")
    }
    static func updated(_ relative: String) -> String {
        String(format: String(localized: "chief.memory.sheet.updated", defaultValue: "Updated %@"), relative)
    }
    /// Who saved a note: Chief in a turn (`chief`), someone running `cmux chief memory add` in a
    /// terminal (`cli`; notes Chief saved before turns were told apart carry it too, so it names
    /// the command line, not a person), the user in the app (`app`), or another tag shown as is.
    static func source(_ tag: String) -> String {
        switch tag {
        case "chief": String(localized: "chief.memory.source.chief", defaultValue: "Saved by Chief")
        case "cli": String(localized: "chief.memory.source.cli", defaultValue: "Saved from the command line")
        case "app": String(localized: "chief.memory.source.you", defaultValue: "Saved by you")
        default: tag
        }
    }

    // MARK: Transcript

    static func willRemember(_ fact: String) -> String {
        String(format: String(localized: "chief.memory.willRemember", defaultValue: "Chief will remember: %@"), fact)
    }
    static var undo: String { String(localized: "chief.memory.undo", defaultValue: "Undo") }
    static var undoHelp: String {
        String(localized: "chief.memory.undo.help", defaultValue: "Forget this note")
    }

    // MARK: Time

    /// "2 min ago", "yesterday", in the user's language.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "chief.memory.justNow", defaultValue: "just now")
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
