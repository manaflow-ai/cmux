import Foundation

/// Restart notice and held page strings (Resources/Localizable.xcstrings).
enum CrashStrings {
    static var restartNotice: String {
        String(localized: "app.restart.notice", defaultValue: "cmux restarted after a problem.", bundle: .module.inAppLanguage)
    }

    static var showLog: String {
        String(localized: "app.restart.showLog", defaultValue: "Show Crash Log", bundle: .module.inAppLanguage)
    }

    static var report: String {
        String(localized: "app.restart.report", defaultValue: "Report", bundle: .module.inAppLanguage)
    }

    /// "Cause: NSRangeException: ..."; `cause` is not translated.
    static func cause(_ cause: String) -> String {
        String(format: String(localized: "app.restart.cause", defaultValue: "Cause: %@", bundle: .module.inAppLanguage), cause)
    }

    /// On the one restored page a restart loop holds (`LaunchRecovery.crashedPages`).
    static var crashedPageNotice: String {
        String(localized: "app.restart.crashedPage", defaultValue: "cmux quit unexpectedly twice while this page was loading, so it was not loaded again. Reload to open it.", bundle: .module.inAppLanguage)
    }
}
