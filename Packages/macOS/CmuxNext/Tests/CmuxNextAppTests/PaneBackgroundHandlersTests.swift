@testable import CmuxNextApp
import Testing

/// The values `pane set-background` takes (plans/cmux-next/pane-backgrounds-DESIGN.md): the
/// vocabulary of `appearance.background` plus `inherit`; anything else is refused.
struct PaneBackgroundHandlersTests {
    @Test(arguments: ["inherit", "none", "daily", "desktop", "system:/System/Library/Desktop Pictures/Sequoia.heic",
                      "file:/Users/Shared/Harbor.png"])
    func acceptsTheBackgroundVocabulary(_ value: String) {
        #expect(PaneBackgroundHandlers.acceptsBackground(value))
    }

    @Test(arguments: ["", "file:relative.png", "system:", "__not_a_backdrop__"])
    func refusesOtherText(_ value: String) {
        #expect(!PaneBackgroundHandlers.acceptsBackground(value))
    }
}

/// `appearance set|reset --property theme` forwards to the one theme path of each level.
struct AppearanceThemeForwardingTests {
    @Test func eachLevelForwardsToItsThemeAction() {
        #expect(PaneBackgroundHandlers.themeAction(.window, set: true) == "space.setTheme")
        #expect(PaneBackgroundHandlers.themeAction(.workspace, set: false) == "workspace.clearTheme")
        #expect(PaneBackgroundHandlers.themeAction(.tab, set: true) == "terminal.setTheme")
        // A pane's theme has no saved row of its own elsewhere: the appearance store keeps it.
        #expect(PaneBackgroundHandlers.themeAction(.pane, set: true) == nil)
    }
}
