@testable import CmuxVNCWebRTC
import Testing

/// RFD 0088 slice 3b, nothing on an idle screen: the host repeats a still
/// picture a few times for the encoder, then sends no video until the
/// picture changes or something asks for it again.
struct IdleRefreshTests {
    typealias Policy = ScreenStreamHost.IdleRefresh
    static let period = Policy.periodNs

    @Test func aNewPictureIsRepeatedABoundedNumberOfTimesThenNothing() {
        var policy = Policy()
        policy.pushed(now: 0, fresh: true)
        var now: UInt64 = 0
        var repeats = 0
        for _ in 0 ..< 40 {
            now += Self.period
            if policy.repeatNow(now: now) {
                repeats += 1
                policy.pushed(now: now, fresh: false)
            }
        }
        #expect(repeats == Policy.repeats)
        #expect(policy.isIdle(now: now + Self.period))
    }

    @Test func noRepeatWhileThePictureIsFresh() {
        var policy = Policy()
        policy.pushed(now: 1_000, fresh: true)
        let early = policy.repeatNow(now: 1_000 + Self.period / 2)
        #expect(!early)
        #expect(!policy.isIdle(now: 1_000 + Self.period * 10), "repeats are still owed")
    }

    @Test func armingOnAStillScreenRepeatsAgain() {
        var policy = Policy()
        policy.pushed(now: 0, fresh: true)
        var now: UInt64 = 0
        while !policy.isIdle(now: now) {
            now += Self.period
            if policy.repeatNow(now: now) { policy.pushed(now: now, fresh: false) }
        }
        let whileIdle = policy.repeatNow(now: now + Self.period)
        #expect(!whileIdle)
        policy.arm() // a keyframe request, a quality change, the viewer's refresh
        let afterArm = policy.repeatNow(now: now + Self.period)
        #expect(afterArm)
        #expect(policy.remaining == Policy.repeats - 1)
    }

    /// Regression: the viewer's own 3 s no-frame keyframe request re-armed
    /// the repeats, so a still screen still sent 4 frames every few seconds.
    @Test func theReceiversTimeoutRequestDoesNotRepeatAStillScreen() {
        var policy = Policy()
        policy.pushed(now: 1, fresh: true)
        var now: UInt64 = 1
        while !policy.isIdle(now: now) {
            now += Self.period
            if policy.repeatNow(now: now) { policy.pushed(now: now, fresh: false) }
        }
        let lastPicture = now - Self.period
        policy.keyframeRequested(now: lastPicture + 3_000_000_000)
        #expect(policy.remaining == 0)
        policy.keyframeRequested(now: lastPicture + 500_000_000) // a loss right after the picture
        #expect(policy.remaining == Policy.repeats)
    }

    @Test func nothingToRepeatBeforeTheFirstPicture() {
        var policy = Policy()
        let beforeFirst = policy.repeatNow(now: Self.period * 3)
        #expect(!beforeFirst)
    }
}
