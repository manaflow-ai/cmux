import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing

/// `QuitDeadline.endSooner` (the engine stop's bound, cmuxterm-hq#11994): it moves an armed deadline
/// earlier, never later, and the end runs once whichever limit passes first.
@Suite(.serialized)
struct QuitDeadlineSoonerTests {
    @Test func aSoonerEndMovesTheArmedDeadlineEarlierAndEndsOnce() async throws {
        let ends = Ends()
        let deadline = QuitDeadline(reason: "a test", end: { ends.mark() })
        deadline.arm(after: .milliseconds(900))
        deadline.endSooner(after: .milliseconds(100), reason: "a sooner test")
        #expect((deadline.timeLeft() ?? .zero) <= .milliseconds(100))
        try await Task.sleep(for: .milliseconds(1_300))
        let times = ends.times()
        #expect(times.count == 1, "the end ran \(times.count) times")
        #expect(times.first.map { $0 < .milliseconds(600) } == true, "the end ran at \(times)")
    }

    @Test func aLaterEndNeverMovesItLater() async throws {
        let ends = Ends()
        let deadline = QuitDeadline(reason: "a test", end: { ends.mark() })
        deadline.arm(after: .milliseconds(100))
        deadline.endSooner(after: .seconds(5), reason: "a later test")
        try await Task.sleep(for: .milliseconds(700))
        let times = ends.times()
        #expect(times.count == 1)
        #expect(times.first.map { $0 < .milliseconds(600) } == true, "the end ran at \(times)")
    }

    @Test func aSoonerEndArmsAnUnarmedDeadline() async throws {
        let ends = Ends()
        let deadline = QuitDeadline(reason: "a test", end: { ends.mark() })
        #expect(deadline.timeLeft() == nil)
        deadline.endSooner(after: .milliseconds(50), reason: "a test")
        deadline.arm(after: .seconds(5))
        try await Task.sleep(for: .milliseconds(500))
        #expect(ends.times().count == 1)
    }
}

/// When a deadline's end ran, from its creation, on any thread.
private nonisolated final class Ends: Sendable {
    private let made = ContinuousClock.now
    private let state = Mutex<[Duration]>([])

    func mark() {
        let at = ContinuousClock.now - made
        state.withLock { $0.append(at) }
    }

    func times() -> [Duration] { state.withLock { $0 } }
}
