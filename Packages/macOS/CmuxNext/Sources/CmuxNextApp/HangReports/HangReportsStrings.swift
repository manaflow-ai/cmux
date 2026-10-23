import Foundation

/// The hang report ask and refusal texts (Resources/HangReports.xcstrings).
enum HangReportsStrings {
    static var askTitle: String {
        String(localized: "hangReports.ask.title", defaultValue: "Help Make cmux Faster?", table: "HangReports", bundle: .module)
    }

    static var askDetail: String {
        String(localized: "hangReports.ask.detail",
               defaultValue: "Send a daily report of hangs and slow frames from this Nightly build. It holds call stacks and timings, never file names, text or web addresses. Settings has the switch and shows what is sent.",
               table: "HangReports", bundle: .module)
    }

    static var askYes: String {
        String(localized: "hangReports.ask.yes", defaultValue: "Send Hang Reports", table: "HangReports", bundle: .module)
    }

    static var askNo: String {
        String(localized: "hangReports.ask.no", defaultValue: "Not Now", table: "HangReports", bundle: .module)
    }

    static var unavailable: String {
        String(localized: "hangReports.unavailable", defaultValue: "Hang reports are not available in this build.",
               table: "HangReports", bundle: .module)
    }
}
