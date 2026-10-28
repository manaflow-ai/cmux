import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// CmuxNextApp's timers after p14-energy-019a: every sleep that stays asks the OS for WakeLeeway's slack, a one-shot
/// deadline is a MainDeadline on the main thread's one wake-up queue, a periodic loop is a timer re-armed after each
/// run (off the main thread when nothing on it needs the result), and a race against a limit is a ``Deadline`` on an
/// injected clock. Deadline tests fire MainDeadlineRig's queue; clock tests advance a ManualClock.
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

    // MARK: Upload stage expiry

    @Test func theStageExpiryFiresAtTheEarliestStagePurgesItOffMainAndMovesToTheNext() async throws {
        let rig = MainDeadlineRig()
        let folder = FileManager.default.temporaryDirectory.appending(path: "stage-expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let early = folder.appending(path: "staged-early"), late = folder.appending(path: "staged-late")
        for stage in [early, late] { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let stages = StageTable(stages: [early: start.addingTimeInterval(600), late: start.addingTimeInterval(900)])
        let work = BackgroundWork(filesWidths: .serial, label: "test.stage-expiry")
        let expiry = MainDeadline(owner: "test.stageExpiry", workClass: .background, scheduler: rig.deadlines)
        let now: @MainActor () -> Date = { start.addingTimeInterval(rig.elapsed) }

        #expect(!expiry.isScheduled)
        AgentChatUploads.armStageExpiry(expiry, next: stages.next, work: work, now: now) { stages.purge(now: $0) }
        #expect(expiry.isScheduled, "the stages' expiry armed no deadline")
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(600) && $0 <= .seconds(601) } == true,
                "the one wake is at the earliest stage's expiry")

        rig.fireAndRun()
        #expect(Array(stages.dates.keys) == [late], "the expired stage was not taken out")
        await Self.drainFiles(work)
        #expect(!FileManager.default.fileExists(atPath: early.path), "the expired stage's folder was not removed")
        #expect(FileManager.default.fileExists(atPath: late.path), "a live stage's folder was removed")
        #expect(expiry.isScheduled, "the expiry did not move to the next stage")
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(299) && $0 <= .seconds(301) } == true,
                "the next wake is at the late stage's expiry")

        rig.fireAndRun()
        await Self.drainFiles(work)
        #expect(stages.dates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: late.path))
        #expect(!expiry.isScheduled, "no stage left kept a deadline")
        #expect(rig.deadlines.nextFire == nil)
    }

    @Test func aStageRefreshedBeforeItsExpiryIsKept() {
        let rig = MainDeadlineRig()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let stage = URL(fileURLWithPath: "/tmp/never-created-stage-\(UUID().uuidString)")
        let stages = StageTable(stages: [stage: start.addingTimeInterval(600)])
        let work = BackgroundWork(label: "test.stage-refresh")
        let expiry = MainDeadline(owner: "test.stageExpiry", workClass: .background, scheduler: rig.deadlines)
        let now: @MainActor () -> Date = { start.addingTimeInterval(rig.elapsed) }
        AgentChatUploads.armStageExpiry(expiry, next: stages.next, work: work, now: now) { stages.purge(now: $0) }

        rig.advance(by: .seconds(300))
        stages.dates[stage] = start.addingTimeInterval(900)
        AgentChatUploads.armStageExpiry(expiry, next: stages.next, work: work, now: now) { stages.purge(now: $0) }
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(600) && $0 <= .seconds(601) } == true,
                "a chunk's later date did not move the deadline")
        rig.fireAndRun()
        #expect(stages.dates.isEmpty, "the refreshed stage did not expire at its new date")
        #expect(!expiry.isScheduled)

        AgentChatUploads.armStageExpiry(expiry, next: nil, work: work, now: now) { stages.purge(now: $0) }
        #expect(!expiry.isScheduled)
    }

    // MARK: Cloud access triage rounds

    @Test func aTriageRoundRunsOnceThenTheNextAfterItsPause() async throws {
        let rig = MainDeadlineRig()
        let asks = CloudAccessAsks()
        let poll = RoundGate()
        let work = BackgroundWork(label: "test.triage")

        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await poll.waitForRounds(1)
        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await Task.yield()
        #expect(poll.started == 1, "a start while a round runs started another")
        #expect(rig.deadlines.nextFire == nil, "a round in flight planned the next one")

        poll.answer(.seconds(30))
        await Self.settleRound(asks, rig)
        #expect(!asks.isTriaging)
        #expect(asks.isTriageScheduled, "the round's pause planned no next round")
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(30) && $0 <= .seconds(31) } == true, "the next round is one pause away")
        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await Task.yield()
        #expect(poll.started == 1, "a start during the pause skipped it")

        rig.fireAndRun()
        await poll.waitForRounds(2)
        #expect(!asks.isTriageScheduled, "the next round's deadline stayed pending while it ran")
        poll.answer(.seconds(30))
        await Self.settleRound(asks, rig)
        #expect(asks.isTriageScheduled, "the second round's pause planned no third")
    }

    /// Under Energy Saver a round's pause is stretched four times.
    @Test func aTriageRoundsPauseIsStretchedUnderTheSaver() async throws {
        let rig = MainDeadlineRig()
        let asks = CloudAccessAsks()
        let poll = RoundGate()
        let work = BackgroundWork(label: "test.triage")

        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(EnergyPolicy(saverReason: .battery)), poll: poll.round)
        await poll.waitForRounds(1)
        poll.answer(.seconds(30))
        await Self.settleRound(asks, rig)
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(120) && $0 <= .seconds(121) } == true, "the saver's pause is four pauses")
    }

    @Test func aRoundThatAnswersNilStopsTheRoundsUntilTheNextStart() async throws {
        let rig = MainDeadlineRig()
        let asks = CloudAccessAsks()
        let poll = RoundGate()
        let work = BackgroundWork(label: "test.triage")

        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await poll.waitForRounds(1)
        poll.answer(nil)
        await Self.settleRound(asks, rig)
        #expect(!asks.isTriaging, "a stopped round stayed in flight")
        #expect(!asks.isTriageScheduled, "a round that answered nil planned another")
        #expect(rig.deadlines.nextFire == nil, "the stopped rounds kept a wake")

        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await poll.waitForRounds(2)
        #expect(poll.started == 2, "a start after the rounds stopped ran no round")
        poll.answer(nil)
        await Self.settleRound(asks, rig)
    }

    @Test func releasedAsksRunNoNextRound() async throws {
        let rig = MainDeadlineRig()
        var asks: CloudAccessAsks? = CloudAccessAsks()
        let poll = RoundGate()
        let work = BackgroundWork(label: "test.triage")

        asks?.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await poll.waitForRounds(1)
        poll.answer(.seconds(30))
        await Self.settleRound(asks, rig)
        #expect(asks?.isTriageScheduled == true)
        asks = nil
        rig.fireAndRun()
        await Task.yield()
        #expect(poll.started == 1, "a released CloudAccessAsks ran its next round")
    }

    /// A round that ends while the app still launches posts its end and awaits nothing the launch
    /// holds (the app's held-await report is a Debug assertion); the end runs once the reveal opens background work.
    @Test func aRoundEndingWhileLaunchingAwaitsNoHeldWork() async throws {
        let held = HeldAwaits()
        let startup = StartupPhase(clock: ManualClock(), ledger: WakeupLedger()) { held.owners.append($0.owner) }
        let rig = MainDeadlineRig(startup: startup)
        let asks = CloudAccessAsks()
        let poll = RoundGate()
        let work = BackgroundWork(label: "test.triage")

        asks.startRounds(deadlines: rig.deadlines, work: work, energy: EnergyPolicySource(), poll: poll.round)
        await poll.waitForRounds(1)
        poll.answer(.seconds(30))
        await Self.settleRound(asks, rig, passes: 40)
        #expect(held.owners.isEmpty, "the round's end awaited background work the launch holds: \(held.owners)")
        #expect(asks.isTriaging, "the round's end ran before the reveal opened background work")

        startup.noteFirstFrame()
        await Self.settleRound(asks, rig)
        #expect(!asks.isTriaging, "the round's end never ran after the reveal")
        #expect(asks.isTriageScheduled, "the round's pause planned no next round")
        #expect(held.owners.isEmpty)
    }

    /// Runs the rig's frames until the round in flight ended: its end is one background task posted from off main,
    /// so each pass also runs the main run loop, where that post arrives.
    private static func settleRound(_ asks: CloudAccessAsks?, _ rig: MainDeadlineRig, passes: Int = 400) async {
        for _ in 0..<passes where asks?.isTriaging == true {
            runMainLoopPass(for: 0.001)
            rig.frame()
            await Task.yield()
        }
    }

    /// Returns once the files lane ran what was posted on it at best effort before (`work` has one slot per priority).
    private static func drainFiles(_ work: BackgroundWork) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            work.post(.bestEffort, mayBlock: .files) { continuation.resume() }
        }
    }

    // MARK: Races against a limit

    @Test func holdsAnswersTrueWhenTheConditionComesBeforeTheLimit() async throws {
        let clock = ManualClock()
        let flag = SleepFlag()
        let rig = MainDeadlineRig()
        // task-owner: the race; the test awaits its answer
        let race = Task { @MainActor in await CloudMove.holds(within: .seconds(30), on: rig.deadlines.work, clock: clock) { flag.on } }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.tolerance == WakeLeeway.window(delay: .seconds(30)).tolerance)
        flag.on = true
        // The wait's observation flushes on the next frame (its class is visible).
        rig.frame()
        #expect(await race.value, "the condition came first, yet the race answered false")
    }

    @Test func holdsAnswersFalseWhenTheLimitPassesFirst() async throws {
        let clock = ManualClock()
        let flag = SleepFlag()
        let rig = MainDeadlineRig()
        // task-owner: the race; the test awaits its answer
        let race = Task { @MainActor in await CloudMove.holds(within: .seconds(30), on: rig.deadlines.work, clock: clock) { flag.on } }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        #expect(!(await race.value), "the limit passed, yet the race answered true")
    }
}

/// Stages by folder and expiry date, purged as AgentChatUploads and AgentPeerUploads purge theirs.
@MainActor
private final class StageTable {
    var dates: [URL: Date]

    init(stages: [URL: Date]) {
        dates = stages
    }

    var next: Date? { dates.values.min() }

    func purge(now: Date) -> (files: [URL], next: Date?) {
        let expired = dates.filter { $0.value <= now }.map(\.key)
        for folder in expired { dates.removeValue(forKey: folder) }
        return (expired, next)
    }
}

/// A triage poll the test answers: each round waits until ``answer(_:)``.
@MainActor
private final class RoundGate: Sendable {
    private(set) var started = 0
    private var pending: CheckedContinuation<Duration?, Never>?
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var round: @MainActor @Sendable () async -> Duration? {
        { [self] in
            started += 1
            let ready = watchers.filter { $0.count <= started }
            watchers.removeAll { $0.count <= started }
            for watcher in ready { watcher.continuation.resume() }
            return await withCheckedContinuation { pending = $0 }
        }
    }

    func answer(_ pause: Duration?) {
        let waiting = pending
        pending = nil
        waiting?.resume(returning: pause)
    }

    /// Returns once round `count` waits for its answer: the round sets ``pending`` before it suspends.
    func waitForRounds(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }
}

/// The owners of the held-class awaits a launching phase reported.
@MainActor
private final class HeldAwaits {
    var owners: [String] = []
}

@Observable @MainActor
private final class SleepFlag {
    var on = false
}

