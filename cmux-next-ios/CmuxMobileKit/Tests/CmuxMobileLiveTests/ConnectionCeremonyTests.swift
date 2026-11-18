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
        link.send(.dialFailed(generation: link.dialGeneration, reason: "timeout"))
        live.phaseChanged(session)
        return session
    }

    /// Detector: a reconnect after a banner that showed posts no "Connected"; the banner just
    /// goes. The old code set `.connected` for 1.5 s.
    @Test func aReconnectPostsNoConnectedToast() async throws {
        let store = rig.emptyStore()
        let live = await connected(store, PerMacDialer())
        defer { live.stop() }
        live.bannerQuietFor = .milliseconds(50)
        let session = try drop(live)
        await rig.settle { live.banner != nil }
        #expect(live.banner == .reconnecting(to: "Aziz's MacBook Pro", identity: "m1"))
        live.retryConnection()
        live.phaseChanged(session)
        // The link's own phase report publishes "back" (that is what sets `macConnection`); read
        // the banner right then. A second phase report here would clear the old code's flash
        // before it could be seen (it lasted 1.5 s).
        await rig.settle { store.macConnection["m1"] == .connected }
        #expect(live.banner != .connected, "no \"Connected\" after a reconnect")
        #expect(live.banner == nil, "back: no banner, got \(String(describing: live.banner))")
        // The link may report "connected" more than once, and on the old code a second report
        // cleared the flash before a test could see it; so check the one report directly: a
        // connected report while the banner shows leaves no banner, never "Connected" (the old
        // code set `.connected` for 1.5 s right here).
        live.banner = .reconnecting(to: "Aziz's MacBook Pro", identity: "m1")
        live.phaseChanged(session)
        #expect(live.banner != .connected, "a connected report posts no \"Connected\"")
        #expect(live.banner == nil)
    }

    /// Detector: this iPhone offline shows "Offline" with no Retry, and once the network is back
    /// the link redials by itself, with no tap.
    @Test func offlineHasNoRetryAndReconnectsWhenTheNetworkReturns() async throws {
        let store = rig.emptyStore()
        let dialer = PerMacDialer()
        let live = await connected(store, dialer)
        defer { live.stop() }
        live.bannerQuietFor = .milliseconds(50)
        _ = try drop(live)
        live.networkPathChanged(.lost)
        await rig.settle { live.networkOfflineShows }
        #expect(!ConnectionBannerState.offline.offersRetry, "no Retry while this iPhone has no network")
        let dials = dialer.dialCount("m1")
        live.networkPathChanged(.changed("wifi"))
        #expect(!live.networkOfflineShows)
        await rig.settle { store.macConnection["m1"] == .connected }
        #expect(dialer.dialCount("m1") > dials, "the network's return redialed the Mac by itself")
    }
}
#endif
