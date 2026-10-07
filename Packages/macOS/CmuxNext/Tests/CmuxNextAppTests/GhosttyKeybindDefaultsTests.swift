@testable import CmuxNextTerminal
import Testing

/// cmux's Ghostty keybind defaults (`GhosttyRuntime.cmuxDefaultKeybindLines`):
/// Ghostty's macOS `super+j=scroll_to_selection` is unbound (Scroll to
/// Selection moved to Cmd-J J), loaded before the user's files so a later
/// `keybind` line of theirs replaces the unbind inside Ghostty's config.
@MainActor
struct GhosttyKeybindDefaultsTests {
    @Test func cmuxUnbindsCommandJ() {
        #expect(GhosttyRuntime.cmuxDefaultKeybindLines == ["keybind = super+j=unbind"])
    }

    @Test func commandJNoLongerScrollsToTheSelection() {
        _ = GhosttyRuntime.shared
        #expect(!GhosttyRuntime.isBound("scroll_to_selection", configText: ""))
    }

    /// The defaults load first, so a later config line replaces the unbind
    /// in Ghostty's config. (The app's leader still takes Cmd-J first until
    /// its chords are unbound in cmux.json.)
    @Test func aLaterGhosttyConfigLineReplacesTheUnbind() {
        _ = GhosttyRuntime.shared
        #expect(GhosttyRuntime.isBound("scroll_to_selection", configText: "keybind = super+j=scroll_to_selection\n"))
        #expect(GhosttyRuntime.isBound("scroll_to_selection", configText: "keybind = super+shift+k=scroll_to_selection\n"))
    }
}
