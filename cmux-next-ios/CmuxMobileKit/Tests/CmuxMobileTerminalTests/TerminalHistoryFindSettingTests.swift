import CmuxMobileDesign
import Foundation
import Testing

/// Settings → Terminal → Find in Whole History ships on (Leo, cmux#53180: "can we have better
/// cmd f find for terminal gui chats? maybe terminals in general to be honest"). On, Find asks the
/// Mac's `terminal-find` over the whole history; turned off, it searches the rows the phone holds.
@Suite struct TerminalHistoryFindSettingTests {
    @Test func itIsOnUntilTurnedOff() {
        let name = "TerminalHistoryFindSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CmuxMobilePreferences.terminalHistoryFind(defaults) == true)
        defaults.set(false, forKey: CmuxMobilePreferences.Key.terminalHistoryFind)
        #expect(CmuxMobilePreferences.terminalHistoryFind(defaults) == false)
    }
}
