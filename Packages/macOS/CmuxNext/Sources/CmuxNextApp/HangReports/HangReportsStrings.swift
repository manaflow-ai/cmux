import Foundation

/// The hang report ask and refusal texts (Resources/HangReports.xcstrings).
enum HangReportsStrings {
    static var askTitle: String {
        String(localized: "hangReports.ask.title", defaultValue: "Help Make cmux Faster?", table: "HangReports", bundle: .module.inAppLanguage)
    }

    /// What a report holds and never holds: the card's detail, and the confirmation sheet of
    /// `cmux settings set diagnostics.hangReports true --confirm` (both record consent).
    static var privacySummary: String {
        String(localized: "hangReports.privacySummary",
               defaultValue: "A daily report of hangs and slow frames: call stacks, timings and versions. Never file names, paths, text, addresses or titles. View Hang Report shows exactly what is sent.",
               table: "HangReports", bundle: .module.inAppLanguage)
    }

    static var askYes: String {
        String(localized: "hangReports.ask.yes", defaultValue: "Send Hang Reports", table: "HangReports", bundle: .module.inAppLanguage)
    }

    static var askNo: String {
        String(localized: "hangReports.ask.no", defaultValue: "Not Now", table: "HangReports", bundle: .module.inAppLanguage)
    }

    static var unavailable: String {
        String(localized: "hangReports.unavailable", defaultValue: "Hang reports are not available in this build.",
               table: "HangReports", bundle: .module.inAppLanguage)
    }
}
