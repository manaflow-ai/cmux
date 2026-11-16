import AppKit
import CmuxNextDesign
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// Follow-up to #44072's Always Allow on the "Share This Mac" sheet:
/// - only the person's own press at this Mac, on the sheet's window, keeps it (the HID check join
///   consent takes), read as the overview answers;
/// - it belongs to the account that chose it, and sign-out, another account or leaving the hub
///   forgets it and turns the setting off; a cmux-next.json edit alone skips nothing;
/// - this Mac shows its menu bar item whenever it shares, also when no sheet was shown; the sharing
///   bar stays for live sessions.
@MainActor
@Suite(.serialized) struct RemoteShareGrantTests {
    private func grant() -> (RemoteShareGrant, UserDefaults, () -> Int) {
        let suite = "RemoteShareGrantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let made = RemoteShareGrant(defaults: defaults)
        var offs = 0
        made.turnOff = { offs += 1 }
        return (made, defaults, { offs })
    }

    /// A setup whose grants and hub write the test owns: `presented` lists each step's sheet.
    @MainActor final class Setup {
        var permissions = (screen: true, control: true)
        var answers: [String] = []
        var presented: [String] = []
        var enables = 0

        func make() -> CmuxRemoteSharingSetup {
            var setup = CmuxRemoteSharingSetup(host: MacScreenHubHost(share: MacScreenShareHost()))
            setup.refresh = { [unowned self] in permissions }
            setup.requestScreen = {}
            setup.requestControl = {}
            setup.enable = { [unowned self] in enables += 1 }
            return setup
        }

        func present(_ spec: CmuxDialogSpec) -> String {
            presented.append(spec.identifier ?? "")
            return answers.isEmpty ? "cancel" : answers.removeFirst()
        }
    }

    @Test func onlyThePersonsOwnPressKeepsAlwaysAllow() async throws {
        let setup = Setup()
        let made = setup.make()
        func after(_ button: String, person: Bool) async throws -> (shared: Bool, always: Bool) {
            try await made.afterOverview(button, personPressed: person) { setup.present($0) }
        }
        let personsAlways = try await after("always", person: true)
        #expect(personsAlways.shared && personsAlways.always)
        // Another process's press of Always Allow allows this request once.
        let scriptsAlways = try await after("always", person: false)
        #expect(scriptsAlways.shared && !scriptsAlways.always)
        let personsContinue = try await after("continue", person: true)
        #expect(personsContinue.shared && !personsContinue.always)
        let cancelled = try await after("cancel", person: true)
        #expect(!cancelled.shared && !cancelled.always)
        #expect(setup.enables == 3)
        // Always Allow that ends in a declined permission step keeps nothing.
        setup.permissions = (false, false)
        let declined = try await after("always", person: true)
        #expect(!declined.shared && !declined.always)
        #expect(setup.enables == 3)
    }

    private func click(_ type: NSEvent.EventType, at timestamp: TimeInterval, window: Int = 7) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: window,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
    }

    /// The review's case: an Accessibility press of Always Allow while the person types or clicks
    /// in cmux dispatches no event of its own, so the app's latest input (the person's) backs nothing.
    /// The press must also be in the sheet's window (or its overlay panel), not another one.
    @Test func thePressIsReadFromTheEventThatAnswersInTheSheetsWindow() {
        typealias Env = CmuxRemoteActionEnvironment
        let person: (NSEvent) -> Bool = { _ in true }
        let sheet: Set<Int> = [7, 8]
        #expect(!Env.pressedByPerson(nil, inWindows: sheet, now: 100, isPerson: person))
        #expect(Env.pressedByPerson(click(.leftMouseUp, at: 99.9), inWindows: sheet, now: 100, isPerson: person))
        #expect(Env.pressedByPerson(click(.leftMouseUp, at: 99.9, window: 8), inWindows: sheet, now: 100, isPerson: person))
        #expect(!Env.pressedByPerson(click(.leftMouseUp, at: 99.9, window: 9), inWindows: sheet, now: 100, isPerson: person))
        #expect(!Env.pressedByPerson(click(.leftMouseUp, at: 99.9), inWindows: sheet, now: 100, isPerson: { _ in false }))
        #expect(!Env.pressedByPerson(click(.leftMouseUp, at: 98), inWindows: sheet, now: 100, isPerson: person))
        #expect(!Env.pressedByPerson(click(.mouseMoved, at: 99.9), inWindows: sheet, now: 100, isPerson: person))
    }

    /// The overview's press is read inside its answer, while the press's own dispatch runs: an
    /// awaited answer resumes after that dispatch has ended, when the event in hand is another.
    @Test func theOverviewReadsThePressWhileItAnswers() async throws {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened: [Int] = []
        let token = center.observe { if case let .opened(record) = $0 { opened.append(record.id) } }
        defer { center.stopObserving(token) }
        var dispatching = false
        var reads = 0
        let pressed: @MainActor (NSWindow) -> Bool = { shown in
            reads += 1
            return dispatching && shown === window
        }

        for (button, expected) in [("always", true), ("continue", false), ("cancel", false)] {
            let answer = Task { await CmuxRemoteSharingSetup.overviewAnswer(in: window, center: center, personPressed: pressed) }
            for _ in 0..<100 where opened.isEmpty { await Task.yield() }
            let last = opened.popLast()
            let id = try #require(last)
            dispatching = true
            #expect(center.press(id, button: button))
            dispatching = false
            let result = await answer.value
            #expect(result.button == button)
            #expect(result.personPressed == expected)
        }
        // Only Always Allow reads the press.
        #expect(reads == 1)
    }

    @Test func cancellingTheRequestDismissesTheOverview() async throws {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened: [Int] = []
        let token = center.observe { if case let .opened(record) = $0 { opened.append(record.id) } }
        defer { center.stopObserving(token) }
        let answer = Task { await CmuxRemoteSharingSetup.overviewAnswer(in: window, center: center) { _ in true } }
        for _ in 0..<100 where opened.isEmpty { await Task.yield() }
        let id = try #require(opened.first)
        answer.cancel()
        let result = await answer.value
        #expect(result.button == "cancel")
        #expect(!result.personPressed)
        #expect(center.record(id) == nil)
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

    @Test func noAccountRecordsNothing() {
        let (grant, _, _) = grant()
        grant.record()
        #expect(grant.grantedTo == nil)
        #expect(!grant.covers(settingOn: true, managed: false))
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
        typealias Indicator = MacScreenShareIndicator
        #expect(Indicator.rowActions(sessionLive: false, offersRevoke: false) == [Indicator.stopSharingThisMacAction])
        #expect(Indicator.rowActions(sessionLive: true, offersRevoke: true) == [Indicator.stopSharingAction, Indicator.revokeViewerAction])
        #expect(Indicator.rowActions(sessionLive: true, offersRevoke: false) == [Indicator.stopSharingAction])
    }

    /// Shared with no one connected shows the menu bar item only: base's sharing bar is for a live
    /// session (who is connected, Stop Sharing), so it stays down.
    @Test func sharedWithNoSessionRaisesNoSharingBar() {
        let indicator = MacScreenShareIndicator()
        indicator.update(title: MacScreenHubHost.sharedTitle, offersRevoke: false, sessionLive: false)
        #expect(!indicator.showsBar)
        #expect(indicator.rowActions == [MacScreenShareIndicator.stopSharingThisMacAction])
    }
}
