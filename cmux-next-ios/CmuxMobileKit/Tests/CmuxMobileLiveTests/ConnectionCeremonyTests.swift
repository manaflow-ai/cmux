import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Audit 20 (ceremony), Leo, 2026-11-18: "All 4 do em these didn't need my addl input". A
/// reconnect says nothing ("Connected" flashed after every one), and this iPhone being offline
/// offers no Retry that could do nothing: the links redial by themselves when the network returns.
/// The dismissed-banner flaps are `CmuxMobileShellTests/BannerDismissalTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct ConnectionCeremonyTests {
    let rig = MultiMacLinkTests()

    private func connected(_ store: AppStore, _ dialer: PerMacDialer) async -> LiveCoordinator {
        UserDefaults.standard.removeObject(forKey: "cmuxMobile.live.mac.t-multimac")
        let live = rig.coordinator(store: store, dialer: dialer)
        await rig.settle { store.macConnection["m1"] == .connected }
        return live
    }

    /// Drops the focused Mac's link into its retry backoff and publishes the phase.
    private func drop(_ live: LiveCoordinator) throws -> MacSession {
        let session = try #require(live.sessions["m1"])
        let link = session.link
        link.send(.linkDropped(generation: link.dialGeneration, reason: "dropped"))
        link.send(.dialFailed(generation: link.dialGeneration, reason: "timeout"))
        live.phaseChanged(session)
        return session
    }

    /// Detector: a connected report while a "Reconnecting" banner is on screen posts no
    /// "Connected"; the banner just goes. The old code set `.connected` for 1.5 s right here.
    @Test func aReconnectPostsNoConnectedToast() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        let session = try #require(live.sessions["m1"])
        // A reconnect that outlasted the quiet bound: its banner is on screen.
        live.bannerHold.show(.reconnecting(to: "Aziz's MacBook Pro", identity: "m1"))
        #expect(live.banner == .reconnecting(to: "Aziz's MacBook Pro", identity: "m1"))
        live.phaseChanged(session)
        #expect(live.banner == nil, "back: no banner, got \(String(describing: live.banner))")
    }

    /// Detector: this iPhone offline shows "Offline" with no Retry, and once the network is back
    /// the link redials by itself, with no tap.
    @Test func offlineHasNoRetryAndReconnectsWhenTheNetworkReturns() async throws {
        let store = rig.emptyStore()
        let dialer = PerMacDialer()
        let live = await connected(store, dialer)
        defer { live.stop() }
        // Offline, no dial reaches the Mac. Without this the redial right after the drop
        // connected at once, so the network's return found a live link with nothing to
        // redial (this test, from #46665, never ran on base: the macOS pass was red first).
        dialer.setUnreachable("m1", true)
        _ = try drop(live)
        live.networkPathChanged(.lost)
        await rig.settle { if case .waiting = live.sessions["m1"]?.link.phase { true } else { false } }
        #expect(store.isOffline)
        #expect(!ConnectionBannerState.offline.offersRetry, "no Retry while this iPhone has no network")
        let dials = dialer.dialCount("m1")
        dialer.setUnreachable("m1", false)
        live.networkPathChanged(.changed("wifi"))
        #expect(!store.isOffline)
        await rig.settle { store.macConnection["m1"] == .connected }
        #expect(dialer.dialCount("m1") > dials, "the network's return redialed the Mac by itself")
    }
}
#endif
