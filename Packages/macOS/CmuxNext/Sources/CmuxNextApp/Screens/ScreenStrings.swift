import Foundation

/// Screen bar, prompt, and refusal strings (Screens.xcstrings, 21 languages).
nonisolated enum ScreenStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Screens", bundle: .module)
    }

    /// Title of the n-th (1-based) screen that has no name.
    static func untitled(_ number: Int) -> String {
        String(format: text("screens.untitled", "Screen %lld"), number)
    }

    static var iconPromptTitle: String { text("screens.icon.prompt", "Screen Icon") }
    static var groupNamePromptTitle: String { text("screens.group.rename.prompt", "Rename Screen Group") }
    static var barAccessibility: String { text("screens.bar.accessibility", "Screens") }
    /// A screen group with no name, in pickers.
    static var untitledGroup: String { text("screens.group.untitled", "Unnamed Group") }

    // Refusals.
    static func noScreenGroup(_ id: String) -> String { String(format: text("screens.refusal.noGroup", "no screen group %@"), id) }
    static var screenNotInGroup: String { text("screens.refusal.notInGroup", "the screen is not in a group") }
    static var pinnedCannotGroup: String { text("screens.refusal.pinnedCannotGroup", "pinned screens cannot be grouped") }
    static var screenAtEdge: String { text("screens.refusal.atEdge", "the screen is already at the edge") }
    static var noOtherScreens: String { text("screens.refusal.noOthers", "there are no other screens to close") }
    static var noClosedScreen: String { text("screens.refusal.noClosed", "no recently closed screen") }
    static var iconArgumentRequired: String { text("screens.refusal.iconRequired", "an icon argument (SF Symbol name or emoji) is required") }
    static func noSavedScreenGroup(_ id: String) -> String { String(format: text("screens.refusal.noSaved", "no saved screen group %@"), id) }
    static var sameWorkspace: String { text("screens.refusal.sameWorkspace", "the screen is already in that workspace") }
}
