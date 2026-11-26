import CmuxMobileDesignCore
import Foundation
import Testing
@testable import CmuxMobileModel

/// The Settings toggle reads the same default as the terminal (`TerminalScrollDefault`): a fresh install
/// shows Plain Scroll on, and a stored choice stays. Leo, 2026-11-25: "Btw how do you feel about me making
/// it just a normal iOS scroll instead of like by line scroll in the terminal view?"
@MainActor struct TerminalPlainScrollSettingTests {
    @Test func aFreshInstallShowsPlainScrollOnAndAStoredOffStays() throws {
        let suite = "cmuxMobile.tests.plain-scroll.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsStore(defaults: defaults).terminalPlainScroll == TerminalScrollDefault.plainScroll)
        #expect(SettingsStore(defaults: defaults).terminalPlainScroll)

        defaults.set(false, forKey: "cmuxMobile.settings.terminalPlainScroll")
        #expect(!SettingsStore(defaults: defaults).terminalPlainScroll)
    }
}
