import Foundation

/// Restart notice and deferred page strings (Resources/Localizable.xcstrings).
enum CrashStrings {
    static var restartNotice: String {
        String(localized: "app.restart.notice", defaultValue: "cmux restarted after a problem. Your windows and terminals are back.", bundle: .module)
    }

    static var restartNoticeSafe: String {
        String(localized: "app.restart.noticeSafe", defaultValue: "cmux restarted after a problem again. Browser pages were not reopened. Reload a tab to open it.", bundle: .module)
    }

    static var showLog: String {
        String(localized: "app.restart.showLog", defaultValue: "Show Crash Log", bundle: .module)
    }

    static var dismiss: String {
        String(localized: "app.restart.dismiss", defaultValue: "Dismiss", bundle: .module)
    }

    static var deferredPageNotice: String {
        String(localized: "app.restart.deferredPage", defaultValue: "Not reopened after cmux restarted. Reload to open this page.", bundle: .module)
    }
}
