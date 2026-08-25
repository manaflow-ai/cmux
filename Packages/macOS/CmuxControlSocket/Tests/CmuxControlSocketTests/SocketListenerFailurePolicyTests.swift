import Foundation
import Testing

@testable import CmuxControlSocket

@Suite struct SocketListenerFailurePolicyTests {
    @Test func repeatedStartupFailuresAreSampledAtAnHourlyCadence() {
        let policy = SocketListenerFailurePolicy(captureCooldown: 3_600)
        let first = Date(timeIntervalSince1970: 1_000)

        #expect(policy.shouldCapture(lastCapturedAt: nil, now: first))
        #expect(!policy.shouldCapture(
            lastCapturedAt: first,
            now: first.addingTimeInterval(3599)
        ))
        #expect(policy.shouldCapture(
            lastCapturedAt: first,
            now: first.addingTimeInterval(3_600)
        ))
    }

    @Test func missingCaptureTimestampAlwaysAdmitsTheFirstFailure() {
        let policy = SocketListenerFailurePolicy()
        #expect(policy.shouldCapture(lastCapturedAt: nil, now: Date(timeIntervalSince1970: 1)))
    }
}
