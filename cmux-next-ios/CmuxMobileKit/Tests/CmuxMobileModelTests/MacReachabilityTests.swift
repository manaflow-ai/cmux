// The rules run in Rust (cmux-mobile-link-ffi `mac_reachability.rs`), which links on iOS only.
#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileModel

/// cmux#52200: Cosmic Gray read "Offline" on Leo's iPhone for 50 minutes while the Mac was up
/// but overloaded, with no way to retry or see why. Each state the phone can tell apart gets its
/// own words, a last-seen time and Retry.
@Suite struct MacReachabilityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var seen: Date { now.addingTimeInterval(-50 * 60) }

    func mac(online: Bool, quietMs: Int? = nil) -> MacDevice {
        MacDevice(id: "cg", name: "Cosmic Gray", isOnline: online, lastSeenAt: seen, quietMs: quietMs)
    }

    func resolve(_ mac: MacDevice, _ connection: MacConnection?, _ failure: MacLinkFailure? = nil,
                 phoneOffline: Bool = false) -> MacReachability {
        MacReachability.resolve(mac: mac, connection: connection, failure: failure, live: true, phoneOffline: phoneOffline)
    }

    @Test func offlineSaysWhenItWasLastSeenAndOffersRetry() {
        let reach = resolve(mac(online: false), nil)
        #expect(reach == .offline(lastSeenAt: seen))
        #expect(reach.offersRetry)
        #expect(reach.statusText(now: now) == "Last seen 50m ago")
        #expect(reach.message(macName: "Cosmic Gray", now: now).contains("Last seen 50m ago."))
    }

    /// The incident: listed online, but its heartbeat stopped reaching the service.
    @Test func lateHeartbeatIsSlowNotOffline() {
        let reach = resolve(mac(online: true, quietMs: 185_000), nil)
        #expect(reach == .slow(quietSeconds: 180))
        #expect(reach.offersRetry)
        #expect(reach.title(macName: "Cosmic Gray") == "Cosmic Gray isn't responding")
        #expect(reach.statusText(now: now) == "Not responding · heard 3 min ago")
    }

    @Test func freshHeartbeatIsDroppedSoPollsChangeNothing() {
        #expect(mac(online: true, quietMs: 4_000).quietMs == nil)
        #expect(mac(online: true, quietMs: 18_000).quietMs == nil)
        #expect(mac(online: true, quietMs: 18_001).quietMs == 10_000)
        #expect(mac(online: true, quietMs: 25_000) == mac(online: true, quietMs: 29_999))
        // An offline Mac has no heartbeat age.
        #expect(mac(online: false, quietMs: 90_000).quietMs == nil)
    }

    @Test func aLiveLinkWinsOverALateHeartbeat() {
        #expect(resolve(mac(online: true, quietMs: 60_000), .connected) == .connected)
        #expect(resolve(mac(online: true, quietMs: 60_000), .connecting) == .connecting)
    }

    @Test func aDialThatGotNoAnswerSaysSoWithWhatTheServiceSaid() {
        // Listed offline: offline with its last-seen time, whatever the dial said (cmux#52200 walk, step 2).
        let offline = resolve(mac(online: false), nil, .hostUnreachable)
        #expect(offline == .offline(lastSeenAt: seen))
        #expect(offline.title(macName: "Cosmic Gray") == "Cosmic Gray is offline")
        #expect(offline.statusText(now: now) == "Last seen 50m ago")
        // Listed online, not answering (a frozen Mac whose socket the service still holds): not responding.
        let frozen = resolve(mac(online: true), .failed("Offline"), .hostUnreachable)
        #expect(frozen.title(macName: "Cosmic Gray") == "Cosmic Gray isn't responding")
        #expect(frozen.shortStatus == "Not responding")
        #expect(frozen.offersRetry)
        #expect(resolve(mac(online: true), .failed("Offline"), .hostUnreachable) == .noAnswer(listedOnline: true, lastSeenAt: seen))
        // A failed link with no failure recorded yet still says it didn't answer, never "Can't connect".
        #expect(resolve(mac(online: true), .failed("Offline")) == .noAnswer(listedOnline: true, lastSeenAt: seen))
        // A new dial under way is connecting, whatever the last one did.
        #expect(resolve(mac(online: true), .connecting, .hostUnreachable) == .connecting)
    }

    @Test func reachedTheMacButCmuxDidNotAnswerIsServiceDown() {
        let reach = resolve(mac(online: true), .connected, .serviceDown)
        #expect(reach == .serviceDown)
        #expect(reach.offersRetry)
        #expect(reach.message(macName: "Cosmic Gray", now: now).contains("Your sessions stay on the Mac"))
    }

    @Test func authAndPairingAndPhoneNetwork() {
        #expect(resolve(mac(online: true), .failed("Signed out"), .authRequired) == .authRequired)
        #expect(!MacReachability.authRequired.offersRetry)
        #expect(resolve(mac(online: true), .failed("x"), .notAllowed) == .notAllowed)
        #expect(resolve(mac(online: true), nil, phoneOffline: true) == .phoneOffline)
        #expect(resolve(mac(online: true), .connected, phoneOffline: true) == .connected)
    }

    @Test func notLinkedOnlineMacIsNotConnected() {
        #expect(resolve(mac(online: true), nil) == .notConnected)
        #expect(!MacReachability.notConnected.offersRetry)
    }

    @Test func mockModeFollowsPresence() {
        #expect(MacReachability.resolve(mac: mac(online: true, quietMs: 90_000), connection: nil, failure: nil, live: false) == .connected)
        #expect(MacReachability.resolve(mac: mac(online: false), connection: nil, failure: .serviceDown, live: false) == .offline(lastSeenAt: seen))
    }
}

@Suite struct MacRecoveryAttemptTests {
    @Test func stepsAdvanceToConnected() {
        var attempt = MacRecoveryAttempt(step: .mac)
        attempt = attempt.advanced(by: .dialing)
        #expect(attempt == MacRecoveryAttempt(step: .mac))
        attempt = attempt.advanced(by: .linked)
        #expect(attempt.step == .session && attempt.isRunning)
        attempt = attempt.advanced(by: .live)
        #expect(attempt.result == .connected)
        #expect(attempt.outcome(macName: "Cosmic Gray") == "Connected. Your sessions are back.")
    }

    @Test func noAnswerFromTheMacSaysTheServiceWasReached() {
        let attempt = MacRecoveryAttempt(step: .mac).advanced(by: .offline)
        #expect(attempt.result == .failed(.mac))
        #expect(attempt.outcome(macName: "Cosmic Gray")
            == "Reached the cmux service, but not Cosmic Gray. Make sure it's awake and cmux is open, then retry.")
        #expect(MacRecoveryAttempt(step: .mac).advanced(by: .failed(.hostUnreachable)).result == .failed(.mac))
    }

    @Test func daemonSilenceFailsAtTheSessionStep() {
        let attempt = MacRecoveryAttempt(step: .mac).advanced(by: .linked).advanced(by: .failed(.serviceDown))
        #expect(attempt.result == .failed(.session))
        #expect(attempt.outcome(macName: "Cosmic Gray")?.hasPrefix("Reached Cosmic Gray, but cmux on it isn't responding") == true)
    }

    @Test func theServiceStepIgnoresTheLinkAndAnEndedAttemptStays() {
        let service = MacRecoveryAttempt(step: .service)
        #expect(service.advanced(by: .live) == service)
        let ended = MacRecoveryAttempt(step: .mac, result: .failed(.mac))
        #expect(ended.advanced(by: .live) == ended)
        #expect(ended.timedOut() == ended)
    }

    /// All Macs: one Retry over every offline Mac reads as one attempt.
    @Test func combinedAttemptRunsWhileAnyRunsAndConnectsWhenOneDoes() {
        #expect(MacRecoveryAttempt.combined([]) == nil)
        let failed = MacRecoveryAttempt(step: .mac, result: .failed(.mac))
        #expect(MacRecoveryAttempt.combined([failed, MacRecoveryAttempt(step: .session)]) == MacRecoveryAttempt(step: .session))
        #expect(MacRecoveryAttempt.combined([failed, MacRecoveryAttempt(step: .session, result: .connected)])?.result == .connected)
        #expect(MacRecoveryAttempt.combined([failed, MacRecoveryAttempt(step: .service, result: .failed(.service))])
            == MacRecoveryAttempt(step: .mac, result: .failed(.mac)))
    }

    @Test func shortStatusFitsTheHeader() {
        #expect(MacReachability.offline(lastSeenAt: nil).shortStatus == "Offline")
        #expect(MacReachability.slow(quietSeconds: 60).shortStatus == "Not responding")
        #expect(MacReachability.serviceDown.shortStatus == "cmux not answering")
    }

    @Test func aDeadlineFailsWhereTheAttemptStood() {
        #expect(MacRecoveryAttempt(step: .session).timedOut().result == .failed(.session))
        #expect(MacRecoveryAttempt(step: .service).timedOut().outcome(macName: "M")
            == "Couldn't reach the cmux service. Check this iPhone's connection, then retry.")
    }

    @Test func eachStateNamesTheOneActionItOffers() {
        #expect(MacReachability.authRequired.action == .signIn)
        #expect(MacReachability.offline(lastSeenAt: nil).action == .retry)
        #expect(MacReachability.connecting.action == nil)
        #expect(MacRecoveryAttempt().action == nil)
        #expect(MacRecoveryAttempt(step: .service).timedOut().action == .retry)
        #expect(MacRecoveryAttempt(step: .session, result: .connected).action == nil)
    }
}
#endif
