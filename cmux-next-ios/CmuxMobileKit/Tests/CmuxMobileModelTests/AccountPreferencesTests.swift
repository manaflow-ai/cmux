import Foundation
import Testing
@testable import CmuxMobileModel

/// verify/persistence.md: account preferences are live for one account at a
/// time and come back when the same account signs in again.
@Suite struct AccountPreferencesTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "cmux-mobile-prefs-\(UUID().uuidString)")! }

    @Test func anEarlierBuildsLivePreferencesBelongToTheAccountSignedInNow() {
        let d = defaults()
        d.set(true, forKey: "cmuxMobile.setupComplete")
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        #expect(d.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(prefs.currentUserID == "user-a")
    }

    @Test func anUnfinishedSignOutIsPutAwayWhenAnotherAccountSignsIn() {
        let d = defaults()
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        d.set(true, forKey: "cmuxMobile.setupComplete")
        d.set(Data([1]), forKey: "cmuxMobile.lastOpenLocation")
        // No sign-out ran (the app was killed); another account signs in.
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cmuxMobile.setupComplete") == nil)
        #expect(d.object(forKey: "cmuxMobile.lastOpenLocation") == nil)
        prefs.stash(userID: "user-b")
        prefs.activate(userID: "user-a")
        #expect(d.bool(forKey: "cmuxMobile.setupComplete"))
        #expect(d.data(forKey: "cmuxMobile.lastOpenLocation") == Data([1]))
    }

    @Test func aSignedOutFirstLaunchAfterAnOlderBuildDropsItsPreferences() {
        let d = defaults()
        d.set(true, forKey: "cmuxMobile.setupComplete")
        let prefs = AccountPreferences(defaults: d)
        #expect(prefs.settleSignedOut())
        #expect(d.object(forKey: "cmuxMobile.setupComplete") == nil)
        #expect(!prefs.settleSignedOut())
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cmuxMobile.setupComplete") == nil)
    }

    @Test func aWriteAfterSignOutGoesToNobody() {
        let d = defaults()
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        d.set(true, forKey: "cmuxMobile.setupComplete")
        prefs.stash(userID: "user-a")
        // A view saving while it fades out.
        d.set(Data([7]), forKey: "cmuxMobile.lastOpenLocation")
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cmuxMobile.lastOpenLocation") == nil)
        #expect(d.object(forKey: "cmuxMobile.setupComplete") == nil)
        // Read without activating: user-a's record.
        #expect(prefs.value("cmuxMobile.setupComplete", userID: "user-a") as? Bool == true)
    }

    @Test func deviceAndAuthKeysNeverMove() {
        #expect(!AccountPreferences.moves("cmuxMobile.settings.transport"))
        #expect(!AccountPreferences.moves("cmuxMobile.auth.selectedTeam"))
        #expect(!AccountPreferences.moves("cmuxMobile.dev.relayOnly"))
        #expect(AccountPreferences.moves("cmuxMobile.live.mac.team-1"))
        #expect(AccountPreferences.moves("cmuxMobile.setupComplete"))
    }
}
