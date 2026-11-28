import Foundation
import Testing
@testable import CmuxMobileShell

@Suite
struct MobilePresencePushRecoveryThrottleTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let interval = MobilePresencePushRecoveryThrottle.minimumUnchangedEvidenceInterval

    @Test
    func firstUnchangedHeartbeatRecoversThenHeartbeatCadenceIsThrottled() {
        var throttle = MobilePresencePushRecoveryThrottle()

        let first = throttle.shouldRecover(evidenceChanged: false, now: now)
        // ~15s presence heartbeats inside the interval must not restart
        // recovery; this cadence starved in-flight dials during the outage.
        let heartbeat15 = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(15)
        )
        let heartbeat30 = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(30)
        )
        let afterInterval = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(interval)
        )

        #expect(first)
        #expect(!heartbeat15)
        #expect(!heartbeat30)
        #expect(afterInterval)
    }

    @Test
    func changedEvidenceAlwaysRecoversAndReArmsTheThrottle() {
        var throttle = MobilePresencePushRecoveryThrottle()

        let first = throttle.shouldRecover(evidenceChanged: false, now: now)
        let changed = throttle.shouldRecover(
            evidenceChanged: true,
            now: now.addingTimeInterval(5)
        )
        // The changed-evidence pass restarts the unchanged-heartbeat window.
        let unchangedAfterChanged = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(6)
        )
        let afterReArmedInterval = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(5 + interval)
        )

        #expect(first)
        #expect(changed)
        #expect(!unchangedAfterChanged)
        #expect(afterReArmedInterval)
    }

    @Test
    func rewoundWallClockDoesNotFreezeTheThrottle() {
        var throttle = MobilePresencePushRecoveryThrottle()

        let first = throttle.shouldRecover(evidenceChanged: false, now: now)
        let afterRewind = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(-3600)
        )

        #expect(first)
        #expect(afterRewind)
    }

    @Test
    func resetForgetsHistorySoTheNextHeartbeatRecoversImmediately() {
        var throttle = MobilePresencePushRecoveryThrottle()

        let first = throttle.shouldRecover(evidenceChanged: false, now: now)
        let throttled = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(1)
        )
        throttle.reset()
        let afterReset = throttle.shouldRecover(
            evidenceChanged: false,
            now: now.addingTimeInterval(2)
        )

        #expect(first)
        #expect(!throttled)
        #expect(afterReset)
    }
}
