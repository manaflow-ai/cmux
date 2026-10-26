import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextErrorJournal
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// CmuxNextApp's timers after p14-energy-019a: every sleep that stays asks the OS for WakeLeeway's slack, a periodic
/// loop is a repeating deadline on the main thread's one wake-up queue, and a race against a limit is a ``Deadline``.
/// Behavior is unchanged except for that slack.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AppSleepsOnWakeLeewayTests {
    // MARK: Tolerance

    @Test func theFindDebounceAsksForTheWakeLeewayTolerance() async throws {
        let clock = ManualClock()
        let model = FindSectionModel(search: { _, _ in .matches([], limited: false) }, clock: clock)
        model.setRoot(URL(fileURLWithPath: "/tmp/project", isDirectory: true))
        model.type("needle")
        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.tolerance == WakeLeeway.window(delay: FindSectionModel.debounce).tolerance)
        #expect(request.tolerance == .milliseconds(8), "a 250 ms debounce gets Chromium's 8 ms leeway")
        #expect(request.deadline.offset == FindSectionModel.debounce, "the leeway moves the wake later, never the deadline")
        model.pendingSearch?.cancel()
    }

    // MARK: Error journal cadence

    @Test func theErrorJournalHarvestsAtOnceThenOnARepeatingDeadline() async throws {
        let rig = SleepRig()
        let (collected, source) = CountingSource.make()
        let folder = FileManager.default.temporaryDirectory.appending(path: "error-journal-cadence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = ErrorJournalService(journal: ErrorJournal(directory: folder), sources: [source], deadlines: rig.deadlines)

        #expect(service.nextHarvest == nil, "nothing is planned before start")
        service.start()
        for await _ in collected { break }
        let planned = try #require(service.nextHarvest, "start planned no periodic harvest")
        #expect(planned.due == ErrorJournalService.harvestInterval, "the next harvest is one interval after start")
        #expect(planned.rule == .flexible)
        #expect(planned.tolerance > .zero, "the periodic harvest is flexible, so its wake can be shared")

        service.start()
        #expect(service.nextHarvest == planned, "a second start does not move the cadence")

        await service.stop()
        #expect(service.nextHarvest == nil, "stop drops the periodic harvest")
    }

    // MARK: Upload stage expiry

    @Test func theAgentPaneUploadStageExpiryIsOneDeadlineAtTheEarliestDate() {
        let rig = SleepRig()
        let expiry = AgentPaneUploadStageExpiry(owner: "test.stageExpiry", deadlines: rig.deadlines, work: BackgroundWork(label: "test.stage-expiry"))
        #expect(!expiry.isArmed)
        expiry.arm(next: Date().addingTimeInterval(600)) { _ in AgentPaneUploadStageExpiry.Purge(files: [], next: nil) }
        #expect(expiry.isArmed, "a stage's expiry date armed no deadline")
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(599) && $0 <= .seconds(601) } == true,
                "the one wake is at the stage's expiry, not a sleeping task per chunk")
        expiry.arm(next: nil) { _ in AgentPaneUploadStageExpiry.Purge(files: [], next: nil) }
        #expect(!expiry.isArmed, "no stage left kept a deadline")
        #expect(rig.deadlines.nextFire == nil)
    }

    // MARK: Races against a limit

    @Test func holdsAnswersTrueWhenTheConditionComesBeforeTheLimit() async {
        let flag = SleepFlag()
        // task-owner: flips the flag once the race is waiting on it
        Task { @MainActor in
            await Task.yield()
            flag.on = true
        }
        #expect(await CloudMove.holds(within: .seconds(30)) { flag.on })
    }

    @Test func holdsAnswersFalseWhenTheLimitPassesFirst() async {
        let flag = SleepFlag()
        #expect(!(await CloudMove.holds(within: .milliseconds(50)) { flag.on }))
    }
}

/// A source that reports each harvest on a stream.
private struct CountingSource: ErrorHarvestSource {
    let id = "counting"
    let collected: AsyncStream<Void>.Continuation

    static func make() -> (AsyncStream<Void>, CountingSource) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        return (stream, CountingSource(collected: continuation))
    }

    func collect(after cursor: String?) async throws -> ErrorHarvest {
        collected.yield()
        return ErrorHarvest(events: [], cursor: cursor)
    }
}

@Observable @MainActor
private final class SleepFlag {
    var on = false
}

/// The app's deadline scheduler on a wake-up queue whose timer nothing fires, at uptime 0.
@MainActor
private final class SleepRig {
    let deadlines: MainDeadlineScheduler

    init() {
        let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { 0 }) { _ in
            ParkedWakeUpTimer()
        }
        deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()), queue: queue)
    }
}

/// A timer the queue arms and parks; nothing fires it.
private final class ParkedWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}
