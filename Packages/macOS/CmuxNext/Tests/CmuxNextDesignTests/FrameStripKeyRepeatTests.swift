#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextDesign
import Testing

/// The later keys of one frame strip (``FrameStripKeyRepeat``): a person's second key does not come later because
/// the first key's work is long, so a later key is due a whole number of intervals after the first key WENT IN. A
/// strip that counts one interval from the end of each key's work gives a gap that is longer than the one asked
/// for, by that work.
struct FrameStripKeyRepeatTests {
    /// The time since the first key went in, moved by the test: no time passes in it.
    struct Hand {
        var elapsed = Duration.zero

        mutating func pass(_ milliseconds: Int) {
            elapsed += .milliseconds(milliseconds)
        }
    }

    @Test func aLaterKeyIsDueFromTheTimeTheFirstKeyWentIn() {
        let keys = FrameStripKeyRepeat(intervalMilliseconds: 100)
        var hand = Hand()
        hand.pass(34) // The first key's own work, inside its send.
        #expect(keys.delay(beforeKey: 1, elapsed: hand.elapsed) == .milliseconds(66), "the second key is due at 100 ms")
        hand.pass(66 + 120) // That delay, then the second key's own work: longer than the interval.
        #expect(keys.delay(beforeKey: 2, elapsed: hand.elapsed) == .zero, "due at 200 ms, asked at 220: at once, never below zero")
        hand.pass(5)
        #expect(keys.delay(beforeKey: 3, elapsed: hand.elapsed) == .milliseconds(75), "due at 300 ms, asked at 225")
        // The interval that a caller gave, as the strip read it before: 40 ms with none, 1 ms at least.
        #expect(FrameStripKeyRepeat(intervalMilliseconds: nil).interval == .milliseconds(40))
        #expect(FrameStripKeyRepeat(intervalMilliseconds: 0.2).interval == .milliseconds(1))
    }
}
#endif
