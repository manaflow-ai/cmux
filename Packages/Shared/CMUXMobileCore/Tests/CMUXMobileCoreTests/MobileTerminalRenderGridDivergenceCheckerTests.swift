import Foundation
import Testing
@testable import CMUXMobileCore

@Test func checkerThrottlesVerificationToMinInterval() {
    var checker = MobileTerminalRenderGridDivergenceChecker(minInterval: 0.25)
    // First frame with a hash verifies.
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.0) == true)
    // Within the interval: skipped (the read-back is too costly to run per frame).
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.1) == false)
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.24) == false)
    // Past the interval: verifies again, and the clock advances from this check.
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.25) == true)
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.4) == false)
    #expect(checker.shouldVerify(expectedHash: 1, now: 0.5) == true)
}

@Test func checkerSkipsFramesWithoutAHash() {
    var checker = MobileTerminalRenderGridDivergenceChecker(minInterval: 0.0)
    // Legacy producer: no hash -> never verify, and the throttle clock is not
    // consumed, so a later stamped frame still verifies immediately.
    #expect(checker.shouldVerify(expectedHash: nil, now: 10.0) == false)
    #expect(checker.shouldVerify(expectedHash: 7, now: 10.0) == true)
}

@Test func checkerReportsDivergenceOnlyOnAConfirmedMismatch() {
    let checker = MobileTerminalRenderGridDivergenceChecker()
    // Matching hashes -> in sync -> no keyframe.
    #expect(checker.diverges(expectedHash: 42, appliedHash: 42) == false)
    // Different hashes -> stale grid -> request keyframe.
    #expect(checker.diverges(expectedHash: 42, appliedHash: 43) == true)
    // A failed/absent read-back must not trigger a spurious resync loop.
    #expect(checker.diverges(expectedHash: 42, appliedHash: nil) == false)
    #expect(checker.diverges(expectedHash: nil, appliedHash: 43) == false)
}
