import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Relay credential policy (intended shape)")
struct RelayCredentialPolicyTests {
    @Test("Refresh derives from the earliest actual expiry minus lead")
    func expiryDrivenRefresh() {
        let now: Int64 = 1_000
        let next = RelayCredentialSchedule.nextRefresh(
            expiries: [now + 300, now + 900], now: now)
        #expect(next == now + 300 - 60)
    }

    @Test("Credentials without expiry fall back to the legacy cadence")
    func fallbackCadence() {
        let now: Int64 = 1_000
        let next = RelayCredentialSchedule.nextRefresh(expiries: [nil], now: now)
        #expect(next == now + 240)
    }

    @Test("A mixed set honors the shortest-lived credential")
    func mixedSetHonorsShortest() {
        let now: Int64 = 1_000
        let next = RelayCredentialSchedule.nextRefresh(
            expiries: [nil, now + 120], now: now)
        #expect(next == now + 120 - 60)
    }

    @Test("Stale or clock-skewed expiries clamp to a prompt retry, not a hot loop")
    func staleClampsToMinimum() {
        let now: Int64 = 1_000
        let next = RelayCredentialSchedule.nextRefresh(
            expiries: [now - 30], now: now)
        #expect(next == now + RelayCredentialSchedule.minimumDelaySeconds)
    }

    @Test("Jitter fires earlier, never later than the lead")
    func jitterOnlyEarlier() {
        let now: Int64 = 1_000
        let base = RelayCredentialSchedule.nextRefresh(expiries: [now + 300], now: now)!
        let jittered = RelayCredentialSchedule.nextRefresh(
            expiries: [now + 300], now: now, jitterSeconds: 25)!
        #expect(jittered == base - 25)
    }

    @Test("No credentials means nothing to schedule")
    func emptyMeansNil() {
        #expect(RelayCredentialSchedule.nextRefresh(expiries: [], now: 0) == nil)
    }

    @Test("Registry-allow mode holds no client credential")
    func registryAllowHoldsNothing() {
        #expect(!RelayCredentialMode.registryAllow.requiresClientCredential)
        #expect(RelayCredentialMode.tokenMinting.requiresClientCredential)
    }

    @Test("Readiness orders monotonically and gates publication at .published")
    func readinessOrdering() {
        #expect(NextTransportReadiness.starting < .bound)
        #expect(NextTransportReadiness.bound < .relayAttached)
        #expect(NextTransportReadiness.relayAttached < .published)
        #expect(NextTransportReadiness.published >= .published)
    }
}
