import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import Testing

/// Settings' Composer Autocorrect row (`SettingsStore`) and the terminal composer's `+` menu toggle
/// (`@AppStorage(CmuxMobilePreferences.Key.terminalComposerAutocorrect)`) are one preference: each
/// reads what the other wrote, and both start off.
@MainActor
@Suite struct TerminalComposerAutocorrectKeyTests {
    private func freshDefaults() -> UserDefaults {
        let name = "TerminalComposerAutocorrectKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func bothStartOff() {
        let defaults = freshDefaults()
        #expect(SettingsStore(defaults: defaults).terminalComposerAutocorrect == false)
        #expect(CmuxMobilePreferences.terminalComposerAutocorrect(defaults) == false)
    }

    @Test func settingsWritesTheKeyTheComposerReads() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.terminalComposerAutocorrect = true
        #expect(defaults.object(forKey: CmuxMobilePreferences.Key.terminalComposerAutocorrect) as? Bool == true)
        #expect(CmuxMobilePreferences.terminalComposerAutocorrect(defaults) == true)
    }

    @Test func settingsReadsWhatTheComposerWrote() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalComposerAutocorrect)
        #expect(SettingsStore(defaults: defaults).terminalComposerAutocorrect == true)
    }
}
