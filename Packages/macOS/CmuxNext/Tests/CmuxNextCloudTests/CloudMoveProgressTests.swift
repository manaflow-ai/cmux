import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Move to Cloud's working toast line (`CloudMoveProgress`, Rust `moves::progress`): it wakes once, when Rust
/// says the line next changes, and its wake never outlives the move.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudMoveProgressTests {
    @MainActor final class Shown { var lines: [String] = [] }

    @Test func wakesWhenTheLineChangesAndNeverAfterTheMoveEnds() async throws {
        let clock = ManualClock(), shown = Shown()
        let progress = CloudMoveProgress(.move, clock: clock) { shown.lines.append($0) }
        progress.enter(.agent, name: "dev")
        #expect(shown.lines == ["3 of 4 · Handing the agent to dev · about 15 s left"])
        try await clock.waitForSleeper()
        // 13 s left reads "about 15 s" until 10 s are left: one wake, 3 s from now.
        #expect(clock.sleeperDeadlines.map(\.offset) == [.seconds(3)])
        clock.advance(by: .seconds(3))
        try await clock.waitForSleeper()
        #expect(shown.lines.last == "3 of 4 · Handing the agent to dev · about 10 s left")
        #expect(clock.sleeperCount == 1, "one wake at a time")
        progress.end()
        #expect(!progress.isWaiting)
        #expect(clock.sleeperCount == 0, "the move ended: its wake is gone")
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(shown.lines.count == 2, "nothing shows after the move ended")
    }

    @Test func aHeldLineAnOverrunAndAMeasuredCopySetNoWake() async throws {
        let clock = ManualClock(), shown = Shown()
        let progress = CloudMoveProgress(.bringBack, clock: clock) { shown.lines.append($0) }
        progress.enter(.copy, name: "dev")
        try await clock.waitForSleeper()
        progress.hold()
        #expect(!progress.isWaiting && clock.sleeperCount == 0, "a machine update's toast shows meanwhile")
        progress.enter(.copy, name: "dev")
        clock.advance(by: .seconds(10))
        progress.copied(SeedProgress(phase: "copy", filesDone: 301, filesTotal: 1_204))
        // A copy its progress lines measure changes as the next line comes, never on a wake.
        #expect(shown.lines.last?.hasPrefix("2 of 4 · Copying the folder back (1,204 files) · about") == true)
        #expect(!progress.isWaiting)
        progress.enter(.agent, name: "dev")
        clock.advance(by: .seconds(30))
        progress.copied(SeedProgress(phase: "copy"))
        #expect(shown.lines.last?.contains("taking longer than usual") == true)
        #expect(!progress.isWaiting, "an overrun line never changes on its own")
        progress.end()
    }
}
