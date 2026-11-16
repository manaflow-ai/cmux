import Foundation
@testable import CmuxNextMacScreen
import Testing

/// Follow-up to #44072's Always Allow on "Share This Mac?":
/// - only the person's own press at this Mac keeps it (the HID check join consent takes);
/// - it belongs to the account that clicked it, and sign-out, another account or leaving the hub
///   forgets it and turns the setting off; a cmux-next.json edit alone skips nothing;
/// - this Mac shows its menu bar item whenever it shares, also when no dialog was shown.
@MainActor
@Suite struct RemoteShareGrantTests {
    private func grant() -> (RemoteShareGrant, UserDefaults, () -> Int) {
        let suite = "RemoteShareGrantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let made = RemoteShareGrant(defaults: defaults)
        var offs = 0
        made.turnOff = { offs += 1 }
        return (made, defaults, { offs })
    }

    @Test func onlyThePersonsOwnPressKeepsAlwaysAllow() {
        typealias Env = CmuxRemoteActionEnvironment
        #expect(Env.keepsAlways(.always, personPressed: true))
        #expect(!Env.keepsAlways(.always, personPressed: false))
        #expect(!Env.keepsAlways(.allow, personPressed: true))
        #expect(!Env.keepsAlways(.cancel, personPressed: true))
    }

    @Test func theSettingAloneSkipsNothingWithoutTheAccountsClick() {
        let (grant, _, _) = grant()
        grant.accountChanged("user-a")
        #expect(!grant.covers(settingOn: true, managed: false))
        grant.record()
        #expect(grant.covers(settingOn: true, managed: false))
        #expect(!grant.covers(settingOn: false, managed: false))
    }

    @Test func anotherAccountForgetsTheGrantAndTurnsTheSettingOff() {
        let (grant, _, offs) = grant()
        grant.accountChanged("user-a")
        grant.record()
        grant.accountChanged("user-b")
        #expect(offs() == 1)
        #expect(!grant.covers(settingOn: true, managed: false))
        grant.accountChanged("user-a")
        #expect(!grant.covers(settingOn: true, managed: false))
    }

    @Test func signingOutOrLeavingTheHubForgetsTheGrant() {
        let (grant, _, offs) = grant()
        grant.accountChanged("user-a")
        grant.record()
        grant.accountChanged(nil)
        #expect(offs() == 1)
        #expect(grant.grantedTo == nil)
        grant.accountChanged(nil)
        #expect(offs() == 1)
    }

    @Test func theSameAccountAfterARelaunchKeepsIt() {
        let (first, defaults, _) = grant()
        first.accountChanged("user-a")
        first.record()
        let relaunched = RemoteShareGrant(defaults: defaults)
        var offs = 0
        relaunched.turnOff = { offs += 1 }
        relaunched.accountChanged("user-a")
        #expect(offs == 0)
        #expect(relaunched.covers(settingOn: true, managed: false))
    }

    @Test func aManagingTeamsPinCountsWithoutAClick() {
        let (grant, _, _) = grant()
        grant.accountChanged("user-a")
        #expect(grant.covers(settingOn: true, managed: true))
        #expect(!grant.covers(settingOn: false, managed: true))
    }

    @Test func theMenuBarItemShowsWheneverThisMacShares() {
        #expect(MacScreenHubHost.indicatorShows(sessionConnected: false, sharingOn: true))
        #expect(MacScreenHubHost.indicatorShows(sessionConnected: true, sharingOn: false))
        #expect(!MacScreenHubHost.indicatorShows(sessionConnected: false, sharingOn: false))
        let indicator = MacScreenShareIndicator()
        indicator.update(title: MacScreenHubHost.sharedTitle, offersRevoke: false, sessionLive: false)
        #expect(indicator.rowActions == [MacScreenShareIndicator.stopSharingThisMacAction])
        indicator.update(title: "Phone is viewing this Mac", offersRevoke: true)
        #expect(indicator.rowActions == [MacScreenShareIndicator.stopSharingAction, MacScreenShareIndicator.revokeViewerAction])
    }
}
