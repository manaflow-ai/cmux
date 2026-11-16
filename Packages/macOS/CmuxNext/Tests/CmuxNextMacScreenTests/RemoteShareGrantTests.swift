import AppKit
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
        #expect(Env.answer("always", personPressed: true) == .always)
        #expect(Env.answer("always", personPressed: false) == .allow)
        #expect(Env.answer("confirm", personPressed: false) == .allow)
        #expect(Env.answer("cancel", personPressed: true) == .cancel)
    }

    private func click(_ type: NSEvent.EventType, at timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    }

    /// The review's case: an Accessibility press of Always Allow while the person types or clicks
    /// in cmux dispatches no event of its own, so the app's latest input (the person's) backs nothing.
    @Test func thePressIsReadFromTheEventThatAnswers() {
        typealias Env = CmuxRemoteActionEnvironment
        let person: (NSEvent) -> Bool = { _ in true }
        #expect(!Env.pressedByPerson(nil, now: 100, isPerson: person))
        #expect(Env.pressedByPerson(click(.leftMouseUp, at: 99.9), now: 100, isPerson: person))
        #expect(!Env.pressedByPerson(click(.leftMouseUp, at: 99.9), now: 100, isPerson: { _ in false }))
        #expect(!Env.pressedByPerson(click(.leftMouseUp, at: 98), now: 100, isPerson: person))
        #expect(!Env.pressedByPerson(click(.mouseMoved, at: 99.9), now: 100, isPerson: person))
    }

    @Test func turningTheSettingOffForgetsTheGrant() {
        let (grant, _, offs) = grant()
        grant.accountChanged("user-a")
        grant.record()
        grant.settingChanged(on: false)
        #expect(grant.grantedTo == nil)
        #expect(offs() == 0)
        // A later edit turning the setting back on skips nothing.
        #expect(!grant.covers(settingOn: true, managed: false))
        grant.record()
        grant.settingChanged(on: true)
        #expect(grant.covers(settingOn: true, managed: false))
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
