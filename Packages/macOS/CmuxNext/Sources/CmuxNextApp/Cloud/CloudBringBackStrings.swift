import Foundation

/// Bring Back Local's text (``CloudBringBack``). Keys live in Resources/Cloud.xcstrings.
enum CloudBringBackStrings {
    static var bringing: String {
        String(localized: "cloud.bringBack.bringing", defaultValue: "Bringing this chat back to this Mac…", table: "Cloud", bundle: .module)
    }
    static var broughtBack: String {
        String(localized: "cloud.bringBack.broughtBack", defaultValue: "This chat runs on this Mac again.", table: "Cloud", bundle: .module)
    }
    static var notFromMove: String {
        String(localized: "cloud.bringBack.notFromMove", defaultValue: "Bring Back Local works on a chat that moved to Cloud from this Mac.",
               table: "Cloud", bundle: .module)
    }
    static func noFolder(_ path: String) -> String {
        String(format: String(localized: "cloud.bringBack.noFolder", defaultValue: "The chat's folder %@ isn't on this Mac anymore.", table: "Cloud", bundle: .module),
               path)
    }
    /// A sync conflict: `paths` changed both here and on the machine, and nothing came back.
    static func conflict(_ paths: [String]) -> String {
        String(format: String(localized: "cloud.bringBack.conflict",
                              defaultValue: "These files changed both here and on Cloud, so nothing came back: %@. Settle them, then Retry.",
                              table: "Cloud", bundle: .module), ListFormatter.localizedString(byJoining: paths))
    }
    /// The machine's cmux-tui is too old to give the chat back (`machine_outdated`, cx-rppd.13).
    static func outdatedMachine(_ machine: String) -> String {
        String(format: String(localized: "cloud.bringBack.outdatedMachine",
                              defaultValue: "%@ runs an older cmux that can't give this chat back yet. Update the machine to bring it back.",
                              table: "Cloud", bundle: .module), machine)
    }
    static func syncFailed(_ machine: String, _ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.syncFailed", defaultValue: "Couldn't copy the folder back from %1$@: %2$@", table: "Cloud", bundle: .module),
               machine, detail)
    }
    /// The Mac's guard refused the chat for its permission policy (`transfer.policy`); the toast
    /// offers ``askFirst``.
    static var policyBlocks: String {
        String(localized: "cloud.bringBack.policyAsksFirst",
               defaultValue: "This chat approves actions without asking. A chat coming back from Cloud must ask first.",
               table: "Cloud", bundle: .module)
    }
    /// The Mac's guard refused the chat for its mode (`transfer.mode`); the toast offers ``askFirst``.
    static var modeBlocks: String {
        String(localized: "cloud.bringBack.modeAsksFirst",
               defaultValue: "This chat's mode acts without asking. A chat coming back from Cloud must ask first.",
               table: "Cloud", bundle: .module)
    }
    /// "Ask first, then bring back" ran and the guard still refused the policy: it can't be narrowed
    /// on Cloud, so the person changes it in the chat.
    static var policyStillBlocks: String {
        String(localized: "cloud.bringBack.policyBlocks",
               defaultValue: "This chat approves actions without asking. A chat coming back from Cloud must ask first: set it to ask in the chat, then Retry.",
               table: "Cloud", bundle: .module)
    }
    /// "Ask first, then bring back" ran and the guard still refused the mode.
    static var modeStillBlocks: String {
        String(localized: "cloud.bringBack.modeBlocks",
               defaultValue: "This chat's mode acts without asking. A chat coming back from Cloud must ask first: pick an asking mode in the chat, then Retry.",
               table: "Cloud", bundle: .module)
    }
    /// The toast action after a policy or mode refusal: narrow the chat on Cloud to an asking policy
    /// and mode, then bring it back (cx-rppd.10).
    static var askFirst: String {
        String(localized: "cloud.bringBack.askFirst", defaultValue: "Ask first, then bring back", table: "Cloud", bundle: .module)
    }
    /// The Mac's guard refused the chat's agent (`transfer.family`).
    static var familyBlocks: String {
        String(localized: "cloud.bringBack.familyBlocks", defaultValue: "This agent can't take a chat back from Cloud yet, so the chat stays there.",
               table: "Cloud", bundle: .module)
    }
    static var unresolved: String {
        String(localized: "cloud.bringBack.unresolved", defaultValue: "The move back didn't finish, so the chat is paused. Retry to finish it.",
               table: "Cloud", bundle: .module)
    }
    static func tabFailed(_ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.tabFailed", defaultValue: "The chat is back on this Mac, but its tab didn't open: %@",
                              table: "Cloud", bundle: .module), detail)
    }
    static func failed(_ detail: String) -> String {
        String(format: String(localized: "cloud.bringBack.failed", defaultValue: "Couldn't bring the chat back. Try again; if it keeps failing, run `cmux cloud diagnostics`. Reason: %@", table: "Cloud", bundle: .module), detail)
    }
}
