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
