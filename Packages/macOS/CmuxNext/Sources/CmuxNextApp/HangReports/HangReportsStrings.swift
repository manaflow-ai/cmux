import Foundation

/// The hang report and performance data ask and refusal texts (Resources/HangReports.xcstrings).
enum HangReportsStrings {
    static var askTitle: String {
        String(localized: "hangReports.ask.title", defaultValue: "Help Make cmux Faster?", table: "HangReports", bundle: .module)
    }

    /// What a report holds and never holds: the card's detail, and the confirmation sheet of
    /// `cmux settings set diagnostics.hangReports true --confirm` (both record consent).
    static var privacySummary: String {
        String(localized: "hangReports.privacySummary",
               defaultValue: "A daily report of hangs and slow frames from this Nightly build: call stacks, timings, coarse counts of windows and tabs, the cmux and macOS versions, the kind of Mac, and a random install ID that changes every 30 days. It never holds file names, paths, terminal or chat text, web addresses, window titles or host names. View Hang Report shows exactly what is sent.",
               table: "HangReports", bundle: .module)
    }

    static var askYes: String {
        String(localized: "hangReports.ask.yes", defaultValue: "Send Hang Reports", table: "HangReports", bundle: .module)
    }

    static var askNo: String {
        String(localized: "hangReports.ask.no", defaultValue: "Not Now", table: "HangReports", bundle: .module)
    }

    /// The performance data card's title: it confirms `diagnostics.performanceData` turned on in a file this Mac
    /// never agreed to.
    static var performanceDataTitle: String {
        String(localized: "performanceData.ask.title", defaultValue: "Send Performance Data?", table: "HangReports", bundle: .module)
    }

    /// What performance data holds and never holds: the card's detail, and the confirmation sheet of
    /// `cmux settings set diagnostics.performanceData true --confirm` (both record consent).
    static var performanceDataSummary: String {
        String(localized: "performanceData.privacySummary",
               defaultValue: "A daily summary of how fast cmux runs: timing histograms and stability counts, coarse counts of windows and tabs, the cmux and macOS versions, the kind of Mac, and a random install ID that changes every 30 days. It never holds call stacks, file names, paths, terminal or chat text, web addresses, window titles or host names. View Hang Report shows exactly what is sent.",
               table: "HangReports", bundle: .module)
    }

    static var performanceDataYes: String {
        String(localized: "performanceData.ask.yes", defaultValue: "Send Performance Data", table: "HangReports", bundle: .module)
    }

    static var unavailable: String {
        String(localized: "hangReports.unavailable", defaultValue: "Hang reports are not available in this build.",
               table: "HangReports", bundle: .module)
    }
}
