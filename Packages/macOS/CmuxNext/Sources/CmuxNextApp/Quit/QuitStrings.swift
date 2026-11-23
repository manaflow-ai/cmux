import Foundation

/// Quit text: the unsaved and failure dialogs, recovery (Resources/Quit.xcstrings).
enum QuitStrings {
    /// The check box of `DestructiveConfirmation`'s questions.
    static var dontAskAgain: String {
        String(localized: "quit.dontAskAgain", defaultValue: "Don’t ask again", table: "Quit", bundle: .module.inAppLanguage)
    }

    static var failedTitle: String {
        String(localized: "quit.failed.title", defaultValue: "Some sessions did not end", table: "Quit", bundle: .module.inAppLanguage)
    }

    static func failedCloseWorkspace(_ name: String, _ message: String) -> String {
        String(localized: "quit.failed.closeWorkspace", defaultValue: "Workspace “\(name)” did not close: \(message)",
               table: "Quit", bundle: .module.inAppLanguage)
    }

    static func failedListWorkspaces(_ message: String) -> String {
        String(localized: "quit.failed.listWorkspaces", defaultValue: "The workspaces could not be read: \(message)",
               table: "Quit", bundle: .module.inAppLanguage)
    }

    static func failedShutdown(_ message: String) -> String {
        String(localized: "quit.failed.shutdown", defaultValue: "The terminals did not end: \(message)", table: "Quit", bundle: .module.inAppLanguage)
    }

    static var unsavedTitle: String {
        String(localized: "quit.unsaved.title", defaultValue: "Save changes before quitting?", table: "Quit", bundle: .module.inAppLanguage)
    }

    static var unsavedSave: String { String(localized: "quit.unsaved.save", defaultValue: "Save", table: "Quit", bundle: .module.inAppLanguage) }

    static var unsavedDontSave: String {
        String(localized: "quit.unsaved.dontSave", defaultValue: "Don’t Save", table: "Quit", bundle: .module.inAppLanguage)
    }

    static func unsavedSaving(_ title: String) -> String {
        String(format: String(localized: "quit.unsaved.saving", defaultValue: "Saving %@…", table: "Quit", bundle: .module.inAppLanguage), title)
    }

    static func unsavedFailed(_ title: String, _ reason: String) -> String {
        String(format: String(localized: "quit.unsaved.failed", defaultValue: "Could not save %1$@: %2$@", table: "Quit", bundle: .module.inAppLanguage),
               title, reason)
    }

    static func unsavedRefused(_ titles: String) -> String {
        String(format: String(localized: "quit.unsaved.refused",
                              defaultValue: "Not quitting: %@ could not be saved. Save or close it, then quit again.",
                              table: "Quit", bundle: .module.inAppLanguage), titles)
    }

    static func recovered(_ title: String) -> String {
        String(format: String(localized: "recovery.notice", defaultValue: "Recovered unsaved changes in %@", table: "Quit", bundle: .module.inAppLanguage), title)
    }

    static func recoveredChanged(_ title: String) -> String {
        String(format: String(localized: "recovery.noticeChanged",
                              defaultValue: "Recovered unsaved changes in %@. The file changed on disk since.",
                              table: "Quit", bundle: .module.inAppLanguage), title)
    }

    static var recoveredOpen: String { String(localized: "recovery.open", defaultValue: "Open", table: "Quit", bundle: .module.inAppLanguage) }

    /// The question after the first press of the quit shortcut (`QuitShortcutGuard`).
    static var shortcutQuestionTitle: String {
        String(localized: "quit.shortcutQuestion.title", defaultValue: "Quit cmux?", table: "Quit", bundle: .module.inAppLanguage)
    }

    /// Its body; `shortcut` is the quit shortcut's keys ("⌘Q").
    static func shortcutQuestionBody(_ shortcut: String) -> String {
        String(format: String(localized: "quit.shortcutQuestion.body", defaultValue: "Your agents and terminals keep running. Press %@ again to quit.",
                              table: "Quit", bundle: .module.inAppLanguage), shortcut)
    }

    /// Its button: quits now.
    static var shortcutQuestionQuit: String { String(localized: "quit.shortcutWarning.quit", defaultValue: "Quit", table: "Quit", bundle: .module.inAppLanguage) }

    /// acpmux is already shutting down; it may not have ended its agents.
    static var agentsShutdownInProgress: String {
        String(localized: "quit.failed.agentsShutdownInProgress",
               defaultValue: "Agents are still shutting down.",
               table: "Quit", bundle: .module.inAppLanguage)
    }

    /// Agent hosts that are still alive after acpmux stopped.
    static func agentsStillRunning(_ count: Int) -> String {
        String(format: String(localized: "quit.failed.agentsStillRunning", defaultValue: "Agents still running: %lld.",
                              table: "Quit", bundle: .module.inAppLanguage), count)
    }

    static func failedEndAgents(_ message: String) -> String {
        String(localized: "quit.failed.endAgents", defaultValue: "The agents did not end: \(message)", table: "Quit", bundle: .module.inAppLanguage)
    }

    static var failedKeepRunning: String {
        String(localized: "quit.failed.keepRunning", defaultValue: "Quit Anyway leaves them running.",
               table: "Quit", bundle: .module.inAppLanguage)
    }

    static var retry: String {
        String(localized: "quit.button.retry", defaultValue: "Retry", table: "Quit", bundle: .module.inAppLanguage)
    }

    static var quitAnyway: String {
        String(localized: "quit.button.quitAnyway", defaultValue: "Quit Anyway", table: "Quit", bundle: .module.inAppLanguage)
    }
}
