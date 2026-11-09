@testable import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Move to Cloud's working toast line (`CloudMoveProgress`): it asks Rust on each new fact, wakes once when Rust
/// says the line next changes, and its wake never outlives the move. Rust's answers are a test's here (the words
/// and the times are Rust's, `moves::progress`, with its own tests); this pins the glue's timer.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudMoveProgressTests {
    /// Rust as a test: the facts asked, and the answer `answer` gives for them.
    @MainActor final class Rust {
        var asked: [CloudMoveProgress.Facts] = []
        var shown: [String] = []
        let answer: (CloudMoveProgress.Facts) -> CloudMoveProgress.Line?
        init(_ answer: @escaping (CloudMoveProgress.Facts) -> CloudMoveProgress.Line?) { self.answer = answer }
        func progress(_ direction: CloudMoveProgress.Direction, clock: ManualClock) -> CloudMoveProgress {
            CloudMoveProgress(direction, clock: clock, ask: { [self] in asked.append($0); return answer($0) }, show: { [self] in shown.append($0) })
        }
    }

    /// The agent step's countdown: "about 15 s" until 3 s in, then "about 10 s" until 8 s in.
    private static func countdown(_ facts: CloudMoveProgress.Facts) -> CloudMoveProgress.Line? {
        facts.stageMs < 3_000 ? .init(text: "15 s", nextMs: 3_000 - facts.stageMs) : .init(text: "10 s", nextMs: 8_000 - facts.stageMs)
    }

    @Test func wakesWhenRustSaysTheLineChangesAndNeverAfterTheMoveEnds() async throws {
        let clock = ManualClock(), rust = Rust(Self.countdown)
        let progress = rust.progress(.move, clock: clock)
        progress.enter(.agent, name: "dev")
        #expect(rust.shown == ["15 s"])
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines.map(\.offset) == [.seconds(3)], "one wake, when Rust says the line changes")
        clock.advance(by: .seconds(3))
        try await clock.waitForSleeper()
        #expect(rust.shown == ["15 s", "10 s"])
        #expect(rust.asked.last?.stageMs == 3_000)
        #expect(clock.sleeperCount == 1, "one wake at a time")
        progress.end()
        #expect(!progress.isWaiting)
        #expect(clock.sleeperCount == 0, "the move ended: its wake is gone")
        let asks = rust.asked.count
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(rust.asked.count == asks && rust.shown.count == 2, "nothing is asked or shown after the move ended")
    }

    @Test func aHeldLineAndALineThatChangesOnlyWithNewFactsSetNoWake() async throws {
        let clock = ManualClock()
        // A copy's measured line (nextMs nil) changes only with its next progress line.
        let rust = Rust { facts in facts.copy == nil ? Self.countdown(facts) : .init(text: "copy \(facts.copy?.filesDone ?? 0)", nextMs: nil) }
        let progress = rust.progress(.bringBack, clock: clock)
        progress.enter(.copy, name: "dev")
        try await clock.waitForSleeper()
        progress.hold()
        #expect(!progress.isWaiting && clock.sleeperCount == 0, "a machine update's toast shows meanwhile: no wake")
        progress.enter(.copy, name: "dev")
        #expect(rust.shown.last == "15 s", "a held line shows again on the next step")
        progress.copied(SeedProgress(phase: "copy", filesDone: 301, filesTotal: 1_204))
        #expect(rust.shown.last == "copy 301")
        #expect(rust.asked.last?.direction == .bringBack && rust.asked.last?.stage == .copy && rust.asked.last?.name == "dev")
        #expect(!progress.isWaiting && clock.sleeperCount == 0, "the copy's progress lines change it, never a wake")
        progress.copied(SeedProgress(phase: "copy", filesDone: 600, filesTotal: 1_204))
        #expect(rust.shown.last == "copy 600")
        progress.end()
    }

    @Test func theMachineGoesToRustAsCloudNamesIt() {
        let rust = Rust { _ in .init(text: "x", nextMs: nil) }
        let progress = rust.progress(.move, clock: ManualClock())
        progress.reaching(nil)
        progress.enter(.machine, machine: "paused", name: "dev")
        #expect(rust.asked.map(\.machine) == ["new", "paused"])
        #expect(rust.shown == ["x"], "the same text shows once")
        progress.end()
    }
}
