import AppKit
@testable import CmuxNextMacScreen
import CmuxNextDevices
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CmuxScreenKit
import Foundation
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut up and load
/// faster/percievably load faster / whatever it takes / desktop gui, ios, remote, cloud, etc".
/// A Screen Sharing tab said "Connecting to {Mac}…" from the first frame of every connect, and
/// "Reconnecting…" the moment a stream stalled; Settings › Devices said "Connecting…" on every hub
/// redial. Now coming up waits `ScreenSession.connectNoticeDelay` and a reconnect or a redial
/// waits `ScreenSession.reconnectNoticeDelay`, both the shared 10 s bound, on an injected clock; a failure shows at once.
@MainActor
@Suite(.closesItsWindows)
struct MacScreenQuietCardTests {
    nonisolated private static let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

    /// Waits until `done` holds, a task turn at a time (the hold's timer resumes on the main actor).
    private func settle(_ done: () -> Bool) async {
        for _ in 0 ..< 500 where !done() { await Task.yield() }
    }

    @Test func connectingSaysNothingUnderTheBoundThenNamesTheMac() async throws {
        let clock = ManualClock()
        let viewer = MacScreenHubViewer(deviceID: Self.deviceID) { nil }
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio", preferences: ScreenPreferences())
        defer { pane.close() }
        pane.model.quiet = MacScreenCardQuiet(clock: clock)
        #expect(pane.model.card == .hubConnect, "the Connect card waits on the person: never held")
        viewer.phase = .requesting(.full)
        #expect(pane.model.liveCard == .hubRequesting(.full))
        #expect(pane.model.card == nil, "a connect under the bound shows no card")
        try await clock.waitForSleeper()
        clock.advance(by: ScreenSession.connectNoticeDelay - .milliseconds(1))
        #expect(pane.model.card == nil)
        clock.advance(by: .milliseconds(1))
        await settle { pane.model.card != nil }
        #expect(pane.model.card == .hubRequesting(.full), "past the bound the card says it connects")
    }

    @Test func aStretchOfComingUpIsOneHold() async throws {
        let clock = ManualClock()
        let quiet = MacScreenCardQuiet(clock: clock)
        #expect(quiet.shown(.hubRequesting(.view)) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(6))
        // Requesting, connecting and waiting for the picture are one stretch: the wait never restarts.
        #expect(quiet.shown(.connecting(reconnecting: false)) == nil)
        clock.advance(by: ScreenSession.connectNoticeDelay - .seconds(6))
        await settle { quiet.shown(.waitingForPicture) != nil }
        #expect(quiet.shown(.waitingForPicture) == .waitingForPicture)
        // The picture arrived: the stretch ends, and a new connect waits again.
        #expect(quiet.shown(nil) == nil)
        #expect(quiet.shown(.connecting(reconnecting: false)) == nil, "a new connect waits again")
    }

    @Test func aReconnectThatRecoversInsideTenSecondsShowsNoLabel() async throws {
        let clock = ManualClock()
        let quiet = MacScreenCardQuiet(clock: clock)
        #expect(quiet.shown(.connecting(reconnecting: true)) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(9))
        #expect(quiet.shown(.connecting(reconnecting: true)) == nil)
        #expect(quiet.shown(nil) == nil, "recovered: the picture again, and nothing was said")
    }

    @Test func aReconnectThatLastsIsSaidAndAFailureShowsAtOnce() async throws {
        let clock = ManualClock()
        let quiet = MacScreenCardQuiet(clock: clock)
        #expect(quiet.shown(.connecting(reconnecting: true)) == nil)
        try await clock.waitForSleeper()
        clock.advance(by: ScreenSession.reconnectNoticeDelay)
        await settle { quiet.shown(.connecting(reconnecting: true)) != nil }
        #expect(quiet.shown(.connecting(reconnecting: true)) == .connecting(reconnecting: true))
        #expect(quiet.shown(.failed) == .failed, "a real failure shows with Try Again at once")
        #expect(quiet.shown(.ended) == .ended)
    }

    @Test func theHubLinkRedialKeepsTheLastStatusForTenSeconds() async throws {
        let clock = ManualClock()
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-quiet-\(UUID().uuidString)/mac-screen.json")
        let settings = MacScreenDevicesSettings(pages: MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork()))
        settings.linkHold = QuietHold(owner: "test", delay: ScreenSession.reconnectNoticeDelay, clock: clock)
        typealias Status = MacScreenDevicesSettings.State.Status
        let connected = Status(text: "Connected", tone: "success")
        let connecting = Status(text: "Connecting…", tone: "attention")
        #expect(settings.quiet(connected, redialing: false) == connected)
        #expect(settings.quiet(connecting, redialing: true) == connected, "a redial under 10 s says nothing new")
        try await clock.waitForSleeper()
        clock.advance(by: ScreenSession.reconnectNoticeDelay)
        await settle { settings.quiet(connecting, redialing: true) == connecting }
        #expect(settings.quiet(connecting, redialing: true) == connecting, "a redial that lasts is said")
        #expect(MacScreenDevicesSettings.redials(.reconnecting("timeout")))
        #expect(!MacScreenDevicesSettings.redials(.removed), "a link that will not come back is never held")
    }
}
