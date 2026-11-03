package import Foundation

/// Screen bar, prompt, and refusal strings (Screens.xcstrings, 21 languages).
package nonisolated struct ScreenStrings {
    package nonisolated init() {}
    /// The bundle that holds `Resources/Screens.xcstrings` (this module's), for tests.
    package static var bundle: Bundle { .module }
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Screens", bundle: .module)
    }

    /// Title of the n-th (1-based) screen that has no name.
    package static func untitled(_ number: Int) -> String {
        String(format: text("screens.untitled", "Screen %lld"), number)
    }

    package static var barAccessibility: String { text("screens.bar.accessibility", "Screens") }
    /// A screen group with no name, in pickers.
    package static var untitledGroup: String { text("screens.group.untitled", "Unnamed Group") }

    // Refusals.
    package static func noScreenGroup(_ id: String) -> String { text("screens.refusal.groupGone", "That screen group no longer exists.") }
    package static var screenNotInGroup: String { text("screens.refusal.notInGroup", "the screen is not in a group") }
    package static var pinnedCannotGroup: String { text("screens.refusal.pinnedCannotGroup", "pinned screens cannot be grouped") }
    package static var screenAtEdge: String { text("screens.refusal.atEdge", "the screen is already at the edge") }
    package static var noOtherScreens: String { text("screens.refusal.noOthers", "there are no other screens to close") }
    package static var noClosedScreen: String { text("screens.refusal.noClosed", "no recently closed screen") }
    package static var iconArgumentRequired: String { text("screens.refusal.iconRequired", "an icon argument (SF Symbol name or emoji) is required") }
    package static var sameWorkspace: String { text("screens.refusal.sameWorkspace", "the screen is already in that workspace") }
}
