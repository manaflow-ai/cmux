import Foundation

/// How old a saved copy on screen is, for the quiet offline line a page shows past
/// ``QuietStatusGate/threshold`` of an outage: "updated just now", "updated 3 min ago",
/// "updated 2 h ago", "updated 4 d ago". Shared by every page that keeps showing what this
/// phone saved while its Mac can't be reached (the agent chat; the terminal page's
/// `TerminalSavedCopyAge` on #56636 is the same phrase). Leo, 2026-11-25: "And just be able to
/// still like interact with the rest of the app with that saved copy and whatnot."
public enum SavedCopyAge {
    public static func phrase(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:
            return String(localized: "savedCopy.updated.now", defaultValue: "updated just now", bundle: .module)
        case ..<3600:
            return String(localized: "savedCopy.updated.minutes", defaultValue: "updated \(seconds / 60) min ago", bundle: .module)
        case ..<86_400:
            return String(localized: "savedCopy.updated.hours", defaultValue: "updated \(seconds / 3600) h ago", bundle: .module)
        default:
            return String(localized: "savedCopy.updated.days", defaultValue: "updated \(seconds / 86_400) d ago", bundle: .module)
        }
    }
}
