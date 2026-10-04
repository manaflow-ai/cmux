import Foundation

/// Quit dialog text (Resources/Quit.xcstrings).
enum QuitStrings {
    static var title: String {
        String(localized: "quit.title", defaultValue: "Quit cmux?", table: "Quit", bundle: .module)
    }

    static func terminalsKeepRunning(_ count: Int) -> String {
        String(localized: "quit.terminalsKeepRunning", defaultValue: "Your \(count) terminals keep running in the background.",
               table: "Quit", bundle: .module)
    }

    static func programsRunning(_ count: Int) -> String {
        String(localized: "quit.programsRunning", defaultValue: "\(count) programs are running.", table: "Quit", bundle: .module)
    }

    static var incognitoCloses: String {
        String(localized: "quit.incognitoCloses", defaultValue: "Incognito windows close, and their programs end.",
               table: "Quit", bundle: .module)
    }

    static var incognitoOnly: String {
        String(localized: "quit.incognitoOnly", defaultValue: "Their running programs end, and their browser data is deleted.",
               table: "Quit", bundle: .module)
    }

    static var remote: String {
        String(localized: "quit.remote", defaultValue: "Sessions on other machines are not affected.", table: "Quit", bundle: .module)
    }

    static var dontAskAgain: String {
        String(localized: "quit.dontAskAgain", defaultValue: "Don’t ask again", table: "Quit", bundle: .module)
    }

    static var keepSessionsRunning: String {
        String(localized: "quit.button.keep", defaultValue: "Keep Sessions Running", table: "Quit", bundle: .module)
    }

    static var quitEverythingEllipsis: String {
        String(localized: "quit.button.quitEverythingEllipsis", defaultValue: "Quit Everything…", table: "Quit", bundle: .module)
    }

    static var quitEverything: String {
        String(localized: "quit.button.quitEverything", defaultValue: "Quit Everything", table: "Quit", bundle: .module)
    }

    static var endTitle: String {
        String(localized: "quit.end.title", defaultValue: "End all terminals?", table: "Quit", bundle: .module)
    }

    static var endEverythingDeletes: String {
        String(localized: "quit.end.body", defaultValue: "End Everything also deletes your workspaces.", table: "Quit", bundle: .module)
    }

    static var endEverything: String {
        String(localized: "quit.button.endEverything", defaultValue: "End Everything", table: "Quit", bundle: .module)
    }

    static var failedTitle: String {
        String(localized: "quit.failed.title", defaultValue: "Some sessions did not end", table: "Quit", bundle: .module)
    }

    static func failedCloseWorkspace(_ name: String, _ message: String) -> String {
        String(localized: "quit.failed.closeWorkspace", defaultValue: "Workspace “\(name)” did not close: \(message)",
               table: "Quit", bundle: .module)
    }

    static func failedListWorkspaces(_ message: String) -> String {
        String(localized: "quit.failed.listWorkspaces", defaultValue: "The workspaces could not be read: \(message)",
               table: "Quit", bundle: .module)
    }

    static func failedShutdown(_ message: String) -> String {
        String(localized: "quit.failed.shutdown", defaultValue: "The terminals did not end: \(message)", table: "Quit", bundle: .module)
    }

    /// acpmux is already shutting down; it may not have ended its agents.
    static var agentsShutdownInProgress: String {
        String(localized: "quit.failed.agentsShutdownInProgress",
               defaultValue: "acpmux is already shutting down, so agents may still be running. Retry waits for the shutdown to finish.",
               table: "Quit", bundle: .module)
    }

    /// Agent hosts that are still alive after acpmux stopped.
    static func agentsStillRunning(_ count: Int) -> String {
        String(format: String(localized: "quit.failed.agentsStillRunning", defaultValue: "Agents still running: %lld.",
                              table: "Quit", bundle: .module), count)
    }

    static func failedEndAgents(_ message: String) -> String {
        String(localized: "quit.failed.endAgents", defaultValue: "The agents did not end: \(message)", table: "Quit", bundle: .module)
    }

    static func failedUnsupported(_ capability: String) -> String {
        String(localized: "quit.failed.unsupported", defaultValue: "This cmux-tui cannot end sessions (\(capability)).",
               table: "Quit", bundle: .module)
    }

    static var failedKeepRunning: String {
        String(localized: "quit.failed.keepRunning", defaultValue: "If you quit anyway, the terminals that did not end keep running.",
               table: "Quit", bundle: .module)
    }

    static var retry: String {
        String(localized: "quit.button.retry", defaultValue: "Retry", table: "Quit", bundle: .module)
    }

    static var quitAnyway: String {
        String(localized: "quit.button.quitAnyway", defaultValue: "Quit Anyway", table: "Quit", bundle: .module)
    }
}
