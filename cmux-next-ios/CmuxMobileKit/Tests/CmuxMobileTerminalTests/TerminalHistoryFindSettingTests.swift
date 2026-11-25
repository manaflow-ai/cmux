import CmuxMobileDesign
import Foundation
import Testing

/// Settings → Terminal → Find in Whole History ships off (Leo, 2026-11-24: "don't
/// unilaterally MERGE ui stuff yet for now until we get better sens of stuff, but having
/// people be able to easily toggle my customieer or whatever would be god"). Off, Find
/// searches the rows the phone holds, as before; on, it asks the Mac's `terminal-find`.
@Suite struct TerminalHistoryFindSettingTests {
    @Test func itIsOffUntilTurnedOn() {
        let name = "TerminalHistoryFindSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CmuxMobilePreferences.terminalHistoryFind(defaults) == false)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalHistoryFind)
        #expect(CmuxMobilePreferences.terminalHistoryFind(defaults) == true)
    }
}
