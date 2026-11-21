import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster". A link or network that is down says nothing on the Workspaces banner until it has
/// been down for `bannerQuietFor` (10 s, `QuietStatusGate.threshold`): the cached screen stays and
/// the link retries on its own. Before, every dial (a cold launch's first one, a foreground
/// redial, a dropped link) showed "Reconnecting…" at once and a "Connected" flash after.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct QuietBannerTests {
    let rig = MultiMacLinkTests()

    /// Drops the focused Mac's link into its retry backoff and publishes the phase.
    private func drop(_ live: LiveCoordinator) throws -> MacSession {
        let session = try #require(live.sessions["m1"])
        let link = session.link
        link.send(.linkDropped(generation: link.dialGeneration, reason: "dropped"))
        link.send(.dialFailed(generation: link.dialGeneration, reason: "timeout"))
        link.send(.dialFailed(generation: link.dialGeneration, reason: "timeout"))
        guard case .waiting = link.phase else {
            Issue.record("expected retry backoff, got \(link.phase)")
            return session
        }
        live.phaseChanged(session)
        return session
    }

    private func connected(_ store: AppStore, _ dialer: PerMacDialer) async -> LiveCoordinator {
        let key = "cmuxMobile.live.mac.t-multimac"
        UserDefaults.standard.removeObject(forKey: key)
        let live = rig.coordinator(store: store, dialer: dialer)
        await rig.settle { store.macConnection["m1"] == .connected }
        return live
    }

    @Test func aDroppedLinkShowsNoBannerUnderTheBound() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        _ = try drop(live)
        #expect(live.banner == nil, "a link down for less than 10 s says nothing, got \(String(describing: live.banner))")
    }

    /// The Mac's fold, Home and its menus read `macConnection`: a failed redial inside the bound
    /// still reads as connecting, not "Can't connect" with Retry.
    @Test func aFailedRedialUnderTheBoundStillReadsConnecting() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        _ = try drop(live)
        #expect(store.macConnection["m1"] == .connecting, "got \(String(describing: store.macConnection["m1"]))")
    }

    @Test func theBannerSpeaksOnceTheBoundPasses() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        live.bannerQuietFor = .milliseconds(200)
        _ = try drop(live)
        #expect(live.banner == nil)
        await rig.settle { live.banner != nil }
        #expect(live.banner == .reconnecting(to: "Aziz's MacBook Pro", identity: "m1"))
    }

    @Test func aRecoveryUnderTheBoundNeverFlashesConnected() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        let session = try drop(live)
        let link = session.link
        live.retryConnection()
        guard case .connecting = link.phase else {
            Issue.record("Retry did not begin a dial: \(link.phase)")
            return
        }
        live.phaseChanged(session)
        #expect(live.banner == nil)
        await rig.settle { store.macConnection["m1"] == .connected }
        live.phaseChanged(session)
        #expect(live.banner == nil, "no \"Connected\" for a banner that never showed")
    }

    /// Battery and perf: a down link holds one sleeping task for its wait, a repeated phase
    /// change adds none, and none is left once the link is back.
    @Test func aDownLinkHoldsOneTimerAndNoneOnceBack() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        let session = try #require(live.sessions["m1"])
        #expect(session.quietTask == nil, "no timer while connected")
        _ = try drop(live)
        let timer = try #require(session.quietTask, "one timer while the link is down")
        live.phaseChanged(session)
        live.phaseChanged(session)
        #expect(session.quietTask.map { $0 == timer } == true, "a repeated phase change starts no second timer")
        live.retryConnection()
        live.phaseChanged(session)
        await rig.settle { store.macConnection["m1"] == .connected }
        live.phaseChanged(session)
        #expect(session.quietTask == nil, "no timer once the link is back")
        #expect(timer.isCancelled, "the wait's task is cancelled, not left sleeping")
    }

    /// Home's toast gate: another Mac's outage waits its own bound, never the time a previous
    /// Mac's outage already ran (switching from one down Mac to another).
    @Test func anotherMacsOutageWaitsItsOwnBound() async {
        let gate = QuietStatusGate(delay: .milliseconds(200))
        gate.update(outage: "m1")
        #expect(!gate.isShown, "under the bound")
        await rig.settle { gate.isShown }
        gate.update(outage: "m1")
        #expect(gate.isShown, "the same outage keeps speaking")
        gate.update(outage: "m2")
        #expect(!gate.isShown, "a second Mac's outage starts its own wait")
        await rig.settle { gate.isShown }
        gate.update(outage: nil)
        #expect(!gate.isShown, "back: nothing")
    }

    /// A link whose wait ran out while the app was away gets a fresh wait on foreground: coming
    /// back shows the cached screen, not "Can't connect" or a banner (`restartQuiet`).
    @Test func foregroundStartsTheWaitAgain() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        live.bannerQuietFor = .milliseconds(200)
        _ = try drop(live)
        await rig.settle { store.macConnection["m1"] == .failed("Offline") }
        #expect(live.banner != nil, "past the bound the outage speaks")
        live.bannerQuietFor = .seconds(60)
        live.foreground()
        #expect(live.banner == nil, "foreground starts the wait again, got \(String(describing: live.banner))")
        #expect(store.macConnection["m1"] != .failed("Offline"), "no Can't connect on return, got \(String(describing: store.macConnection["m1"]))")
    }

    @Test func aLostNetworkSaysOfflineOnlyAfterTheBound() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        live.bannerQuietFor = .milliseconds(200)
        live.networkPathChanged(.lost)
        #expect(store.isOffline, "the Workspaces wording still knows at once")
        #expect(!live.networkOfflineShows, "a Wi-Fi to cellular move says nothing")
        await rig.settle { live.networkOfflineShows }
        live.networkPathChanged(.changed("wifi"))
        #expect(!live.networkOfflineShows)
        #expect(live.networkBannerTask == nil, "no timer is left once the network is back")
        live.networkPathChanged(.lost)
        #expect(live.networkBannerTask != nil, "one sleeping task while the network is gone")
        live.stop()
        #expect(live.networkBannerTask == nil, "stop ends it")
    }
}
#endif
