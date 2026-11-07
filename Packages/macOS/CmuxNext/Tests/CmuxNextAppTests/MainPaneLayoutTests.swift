@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextLayout
import Testing

/// Main pane layout (`layout.mainPane`, Leo 2026-10-20): an agent chat is its screen's one main
/// pane and nothing opens into it. What it opens is a tab in the column on its right, the way a
/// person's new tab from the chat dock opens; a chat alone on its screen docks left first. Any
/// other pane keeps the usual rules. Where it goes is Rust's (cmux-window-rules `chat`, with its
/// cases); `WindowRulesChatTests` checks the round trip.
@MainActor
struct MainPaneLayoutTests {
    @Test func theDebugOverrideWinsOverTheSetting() {
        #expect(MainPaneLayout.isOn(setting: true, override: .setting))
        #expect(!MainPaneLayout.isOn(setting: false, override: .setting))
        #expect(MainPaneLayout.isOn(setting: false, override: .on))
        #expect(!MainPaneLayout.isOn(setting: true, override: .off))
        #expect(MainPaneLayout.debugOverride.defaultValue == .setting, "the setting decides unless Debug Settings says otherwise")
    }

    /// The Debug override is listed, so Debug Settings shows it and `debug.tunables` can set it.
    @Test func theOverrideIsInDebugSettings() {
        #expect(TunableCatalog.all.contains { $0.key == MainPaneLayout.debugOverride.key })
    }
}
