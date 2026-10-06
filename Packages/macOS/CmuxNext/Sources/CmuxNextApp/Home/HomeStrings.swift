import Foundation

/// Home strings (Resources/Home.xcstrings).
nonisolated enum HomeStrings {
    static var title: String { String(localized: "home.title", defaultValue: "Home", table: "Home", bundle: .module) }
    /// The chief's name (N1): the chief conversation's title and the mux's name.
    static var chiefName: String { String(localized: "home.chief.name", defaultValue: "Chief", table: "Home", bundle: .module) }
    static var unavailable: String {
        String(localized: "home.unavailable", defaultValue: "Conversations need a newer cmux daemon.", table: "Home", bundle: .module)
    }
    static var newConversationTitle: String {
        String(localized: "home.newConversation.title", defaultValue: "New Conversation", table: "Home", bundle: .module)
    }
    static var thisMacOnly: String { String(localized: "home.owner.local", defaultValue: "This Mac only", table: "Home", bundle: .module) }
    static var archiveDefaultChief: String {
        String(localized: "home.chief.archive.default", defaultValue: "Make another Chief the default before archiving this one.",
               table: "Home", bundle: .module)
    }
    static var archiveFailed: String {
        String(localized: "home.chief.archive.failed", defaultValue: "The Chief couldn’t be archived. Try again.", table: "Home",
               bundle: .module)
    }
}
