import Foundation
import Testing
@testable import CMUXMobileCore

/// Deterministic generator so minted codes are reproducible in tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

struct CmxPairingCodeTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func mintedProducesSixDigitZeroPaddedCodeAndTTLExpiry() {
        var generator = SeededGenerator(state: 7)
        let minted = CmxPairingCode.minted(ttl: 600, now: now, using: &generator)
        #expect(minted.code.count == 6)
        let allDigits = minted.code.allSatisfy(\.isNumber)
        #expect(allDigits)
        #expect(minted.expiresAt == now.addingTimeInterval(600))
    }

    @Test func instanceLabelsRoundTripThroughActive() {
        let minted = CmxPairingCode(code: "042117", expiresAt: now.addingTimeInterval(600))
        let decoded = CmxPairingCode.active(in: minted.instanceLabels, now: now)
        #expect(decoded == minted)
    }

    @Test func activeRejectsExpiredMissingOrUnparseableExpiry() {
        let expired = CmxPairingCode(code: "042117", expiresAt: now.addingTimeInterval(-1))
        #expect(CmxPairingCode.active(in: expired.instanceLabels, now: now) == nil)
        #expect(CmxPairingCode.active(
            in: [CmxPairingCode.codeLabelKey: "042117"],
            now: now
        ) == nil)
        #expect(CmxPairingCode.active(
            in: [
                CmxPairingCode.codeLabelKey: "042117",
                CmxPairingCode.expiresAtLabelKey: "not-a-date",
            ],
            now: now
        ) == nil)
        #expect(CmxPairingCode.active(in: [:], now: now) == nil)
    }

    @Test func activeAcceptsWholeSecondExpiryForm() {
        let labels = [
            CmxPairingCode.codeLabelKey: "042117",
            CmxPairingCode.expiresAtLabelKey: "1970-01-01T00:33:20Z",
        ]
        let decoded = CmxPairingCode.active(in: labels, now: now)
        #expect(decoded?.code == "042117")
        #expect(decoded?.expiresAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func normalizedClaimInputAcceptsExactlySixDigits() {
        #expect(CmxPairingCode.normalizedClaimInput("042117") == "042117")
        #expect(CmxPairingCode.normalizedClaimInput(" 042 117 ") == "042117")
        #expect(CmxPairingCode.normalizedClaimInput("042-117") == "042117")
        #expect(CmxPairingCode.normalizedClaimInput("42117") == nil)
        #expect(CmxPairingCode.normalizedClaimInput("0421178") == nil)
        #expect(CmxPairingCode.normalizedClaimInput("") == nil)
    }
}
