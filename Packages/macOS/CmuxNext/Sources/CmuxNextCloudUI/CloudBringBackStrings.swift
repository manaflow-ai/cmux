import Foundation

/// Bring Back Local's text (the App's `CloudBringBack`). Keys live in Resources/Cloud.xcstrings.
public struct CloudBringBackStrings {
    public init() {}
    public static var bringing: String {
        String(localized: "cloud.bringBack.bringing", defaultValue: "Bringing this chat back to this Mac…", table: "Cloud", bundle: .module)
    }
    public static var broughtBack: String {
        String(localized: "cloud.bringBack.broughtBack", defaultValue: "This chat runs on this Mac again.", table: "Cloud", bundle: .module)
    }
    public static var notFromMove: String {
        String(localized: "cloud.bringBack.notFromMove", defaultValue: "Bring Back Local works on a chat that moved to Cloud from this Mac.",
               table: "Cloud", bundle: .module)
    }
    public static func noFolder(_ path: String) -> String {
        String(format: String(localized: "cloud.bringBack.noFolder", defaultValue: "The chat's folder %@ isn't on this Mac anymore.", table: "Cloud", bundle: .module),
               path)
    }
    /// A sync conflict: `paths` changed both here and on the machine, and nothing came back.
    public static func conflict(_ paths: [String]) -> String {
        String(format: String(localized: "cloud.bringBack.conflict",
                              defaultValue: "These files changed both here and on Cloud, so nothing came back: %@. Settle them, then Retry.",
                              table: "Cloud", bundle: .module), ListFormatter.localizedString(byJoining: paths))
    }
    /// The machine's cmux-tui is too old to give the chat back (`machine_outdated`, cx-rppd.13).
    public static func outdatedMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.bringBack.outdatedMachine",
                              defaultValue: "%@ runs an older cmux that can't give this chat back yet. Update the machine to bring it back.",
                              table: "Cloud", bundle: .module), machine)
    }
    public static func syncFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.syncFailed", defaultValue: "Couldn't copy the folder back from %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
    public static var unresolved: String {
        String(localized: "cloud.bringBack.unresolved", defaultValue: "The move back didn't finish, so the chat is paused. Retry to finish it.",
               table: "Cloud", bundle: .module)
    }
    public static func tabFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.tabFailed", defaultValue: "The chat is back on this Mac, but its tab didn't open: %@",
                              table: "Cloud", bundle: .module), detail)
    }
    public static func failed(_ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.failedPlain", defaultValue: "Couldn't bring the chat back. %@", table: "Cloud", bundle: .module), detail)
    }
}
