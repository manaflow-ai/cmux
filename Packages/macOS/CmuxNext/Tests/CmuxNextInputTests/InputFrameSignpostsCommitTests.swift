import CmuxNextInput
import CmuxNextInputCore
@testable import CmuxNextSignposts
import Foundation
import Testing

/// The key slots' `key.frame` signposts hand each committed key's time to ``InputFrameSignposts/committedKey``, the
/// seam the app's opt-in hang reports take the black box from at a slow key frame. The test
/// ends the key's turn itself instead of the main run loop's observer.
@MainActor
struct InputFrameSignpostsCommitTests {
    @Test func aCommittedKeyReachesCommittedKeySetBeforeOrAfterTheFirstKey() {
        let keyFrames = KeyFrameSignpost(signposter: Signposter(category: .key))
        var made = 0
        let signposts = InputFrameSignposts(now: { 100.08 }, keyFrames: {
            made += 1
            return keyFrames
        })
        var seen: [UInt64] = []
        signposts.committedKey = { seen.append($0) }
        #expect(made == 0, "the signposts are made at the first key")

        signposts.begin(InputLatencyToken(rawValue: 1), .key, target: .terminal, eventTimestamp: 100)
        keyFrames.runLoopReached(.beforeWaiting)
        #expect(made == 1)
        #expect(seen.count == 1)
        #expect((seen.first ?? 0) >= 80_000, "from the key-down: its 80 ms in the queue counts")

        signposts.committedKey = nil
        signposts.begin(InputLatencyToken(rawValue: 2), .key, target: .other, eventTimestamp: 100)
        keyFrames.runLoopReached(.beforeWaiting)
        #expect(seen.count == 1, "cleared after the first key: nothing gets the second")
        #expect(made == 1)
    }
}
