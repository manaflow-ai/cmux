import Foundation

/// Localized strings of the Task Manager (Resources/Localizable.xcstrings) that Swift says: the
/// kinds, the Kill Process question and its refusals. The page's own words (columns, the empty
/// list, the total) are in webviews/src/pages/task-manager/Localizable.xcstrings.
struct TaskManagerStrings {
    static var title: String { t("taskManager.title", "Task Manager") }
    static var daemon: String { t("taskManager.kind.daemon", "cmux daemon") }
    static var terminal: String { t("taskManager.kind.terminal", "Terminal") }
    static var renderer: String { t("taskManager.kind.renderer", "Browser renderer") }
    static var webContent: String { t("taskManager.kind.webContent", "Web content") }
    static var other: String { t("taskManager.kind.other", "Other") }
    static var killButton: String { t("taskManager.kill.button", "Kill Process") }
    static var killTitle: String { t("taskManager.kill.title", "Kill this process?") }
    static var refusalInvalid: String { t("taskManager.refusal.invalid", "Give a process ID, for example 4242.") }
    static var refusalRemote: String {
        t("taskManager.refusal.remote", "Kill Process ends only processes on this Mac.")
    }
    static var refusalApp: String { t("taskManager.refusal.app", "Kill Process does not end cmux itself. Quit cmux instead.") }
    static var refusalDaemon: String {
        t("taskManager.refusal.daemon", "Kill Process does not end the cmux daemon: every terminal it runs would end.")
    }
    static var refusalNotRunning: String { t("taskManager.refusal.notRunning", "That process is not running.") }
    static var refusalNotCmux: String { t("taskManager.refusal.notCmux", "Kill Process ends only processes that cmux started.") }
    static var refusalSignal: String { t("taskManager.refusal.signal", "The process could not be ended.") }

    static func killBody(name: String, pid: Int32) -> String {
        String(format: t("taskManager.kill.body", "%1$@ (PID %2$@) ends now. Work it has not saved is lost."), name, String(pid))
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
