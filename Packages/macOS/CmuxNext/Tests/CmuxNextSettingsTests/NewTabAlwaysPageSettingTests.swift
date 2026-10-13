import CmuxNextSettings
import Testing

/// New Tab always lands on the New Tab page; a terminal is picked there or through New Terminal
/// Tab, never opened by itself (Leo 2026-10-12). So Settings offers no "New Tab Opens" row: a
/// `tabs.newTabKind` of "terminal" or "same-kind" made Cmd-T on a terminal open a terminal.
struct NewTabAlwaysPageSettingTests {
    @Test func settingsOffersNoNewTabOpensChoice() {
        #expect(SettingsSchema.descriptor(for: ["tabs", "newTabKind"]) == nil)
    }
}
