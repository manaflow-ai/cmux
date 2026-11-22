#if os(iOS)
import CmuxMobileDesign
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up". The banner over
/// Workspaces and Home draws nothing for a link that is down until it has lasted the shared quiet
/// bound, then one "Offline · Retry"; a Mac known to be offline and a signed-out device show at once.
@MainActor
@Suite struct QuietConnectionBannerTests {
    @Test func aDownLinkDrawsNothingUnderTheBound() {
        let banner = QuietConnectionBanner(gate: QuietStatusGate(delay: QuietStatusGate.threshold))
        banner.update(.connectionFailed)
        #expect(banner.shown == nil, "nothing for the first 10 s")
        banner.update(.offline)
        #expect(banner.shown == nil)
        banner.update(.refreshFailed())
        #expect(banner.shown == nil)
    }

    @Test func pastTheBoundItSaysOfflineWithRetry() async throws {
        let banner = QuietConnectionBanner(gate: QuietStatusGate(delay: .milliseconds(60)))
        banner.update(.connectionFailed)
        #expect(banner.shown == nil)
        for _ in 0..<200 where banner.shown == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(banner.shown?.text == "Offline")
        #expect(banner.shown?.offersRetry == true)
        banner.update(nil)
        #expect(banner.shown == nil, "back: the banner goes, with no Connected toast")
    }

    @Test func aBlipUnderTheBoundNeverDraws() async throws {
        let banner = QuietConnectionBanner(gate: QuietStatusGate(delay: .milliseconds(150)))
        banner.update(.connectionFailed)
        try await Task.sleep(for: .milliseconds(30))
        banner.update(nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(banner.shown == nil)
    }

    @Test func statesThePersonActsOnOrKnowsShowAtOnce() {
        let banner = QuietConnectionBanner(gate: QuietStatusGate(delay: QuietStatusGate.threshold))
        banner.update(.signedOut)
        #expect(banner.shown == .signedOut)
        banner.update(.macOffline("Studio"))
        #expect(banner.shown == .macOffline("Studio"))
        banner.update(.waitingForPairing(on: "Studio"))
        #expect(banner.shown == .waitingForPairing(on: "Studio"))
    }
}
#endif
