import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ``DaemonUpdatePolicy`` against fake targets: which machines it updates, in what order, how it
/// waits for an idle moment, what it records and what it shows.
@Suite nonisolated struct DaemonUpdatePolicyTests {
    static let bundled = "abc123def 2026-10-20"
    static let older = "0123456ff 2026-10-01"

    @Test func aFakeOldTargetIsUpdated() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let target = fixture.target("old", build: Self.older, outcomes: [.updated(build: Self.bundled)])
        await fixture.policy([target]).run()

        #expect(fixture.calls == ["old"])
        #expect(await target.currentBuild() == Self.bundled)
        #expect(fixture.states("old") == [.updating, .updated(build: Self.bundled)])
        #expect(fixture.ledger.targets == ["old": "updated"])
        #expect(fixture.notices.isEmpty)
    }

    @Test func targetsOnTheBuildOrUnknownAreLeftAlone() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let targets = [
            fixture.target("same-commit-other-date", build: "abc123def 2026-10-19"),
            fixture.target("same-commit-40-hex", build: "abc123def0123456789abcdef0123456789abcd"),
            fixture.target("unreachable", build: nil),
            fixture.target("nogit", build: "nogit 2026-10-01"),
        ]
        await fixture.policy(targets).run()
        #expect(fixture.calls.isEmpty)
        #expect(fixture.events.isEmpty)
    }

    @Test func aDirtyBundledBuildPushesNothing() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        await fixture.policy([fixture.target("old", build: Self.older)], bundled: "abc123def+dirty.1234abcd 2026-10-20").run()
        #expect(fixture.calls.isEmpty)
    }

    /// A busy machine is asked again after the backoff; the next one goes meanwhile. One at a time.
    @Test func targetsRunOneAtATimeAndABusyOneWaits() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let first = fixture.target("first", build: Self.older, outcomes: [.busy, .updated(build: nil)])
        let second = fixture.target("second", build: Self.older, outcomes: [.current])
        await fixture.policy([first, second], clock: clock).run()

        #expect(fixture.calls == ["first", "second", "first"])
        #expect(clock.sleeps == [.seconds(120)])
        #expect(!fixture.overlapped, "two updates ran at once")
        #expect(fixture.states("first") == [.updating, .waitingForIdle, .updating, .updated(build: "abc123def")])
        #expect(fixture.ledger.targets == ["first": "updated", "second": "current"])
    }

    /// A machine where a long-running agent always works (huge-blue with claude-sr2) never has an
    /// idle moment: every update answers busy. The policy keeps backing off (2, 4, 8, 16, then
    /// every 30 minutes), leaves it for the next launch after six hours, and never forces it; the
    /// target API has no forced update at all.
    @Test func aTargetThatIsNeverIdleIsNeverForced() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let target = fixture.target("huge-blue", build: Self.older, outcomes: [.busy])
        await fixture.policy([target], clock: clock).run()

        let minutes: [Int64] = [2, 4, 8, 16] + Array(repeating: 30, count: 11)
        #expect(clock.sleeps == minutes.map { .seconds($0 * 60) })
        #expect(clock.sleeps.reduce(.zero, +) == .seconds(6 * 3600))
        #expect(fixture.calls.count == minutes.count + 1)
        #expect(await target.currentBuild() == Self.older)
        #expect(fixture.states("huge-blue").last == .waitingForIdle)
        // Not recorded: the next launch waits for an idle moment again.
        #expect(fixture.ledger.targets.isEmpty)
        #expect(fixture.notices.isEmpty)
    }

    /// A failed update shows as failed on the board and as one notice, also when the app
    /// relaunches on the same build (the target is not tried again).
    @Test @MainActor func aFailureShowsItsStateAndOneNotice() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let board = DaemonUpdateBoard()
        var shown: [String] = []
        board.showNotice = { shown.append($0) }
        let apply: @Sendable (DaemonUpdateEvent) async -> Void = { event in await MainActor.run { board.apply(event) } }
        let target = fixture.target("cmux16", build: Self.older, sshHost: "cmux16", outcomes: [.failed(reason: "disk full")])
        await fixture.policy([target], board: apply).run()
        await fixture.policy([target], board: apply).run()

        #expect(fixture.calls == ["cmux16"])
        #expect(board.targets["cmux16"]?.state == .failed(reason: "disk full", rolledBack: false))
        #expect(board.detail(sshHost: "CMUX16") == DaemonUpdateBoard.line(.failed(reason: "disk full", rolledBack: false)))
        #expect(board.detail(id: "cmux16") == board.detail(sshHost: "cmux16"))
        #expect(board.detail(sshHost: "huge-blue") == nil)
        #expect(shown.count == 1)
        #expect(shown.first?.contains("cmux16") == true)
    }

    @Test func aRollbackIsRecordedAndTriedAgainOnlyOnTheNextBuild() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let target = fixture.target("peer", build: Self.older, outcomes: [.rolledBack(reason: "new daemon reported 0123456ff"), .updated(build: nil)])
        await fixture.policy([target]).run()
        await fixture.policy([target]).run()
        #expect(fixture.calls == ["peer"])
        #expect(fixture.ledger.targets == ["peer": "rolledBack"])
        #expect(fixture.notices.map(\.state) == [.failed(reason: "new daemon reported 0123456ff", rolledBack: true)])

        await fixture.policy([target], bundled: "fedcba987 2026-10-21").run()
        #expect(fixture.calls == ["peer", "peer"])
    }

    @Test func noBinaryIsNotRecordedAndSaysNothing() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let target = fixture.target("arm", build: Self.older, outcomes: [.needsBinary(target: "aarch64-unknown-linux-musl")])
        await fixture.policy([target]).run()
        #expect(fixture.ledger.targets.isEmpty)
        #expect(fixture.notices.isEmpty)
        #expect(fixture.states("arm").last == .failed(reason: "no build for aarch64-unknown-linux-musl", rolledBack: false))
    }

    /// A cmux Cloud VM that is also an acpmux ssh peer is updated by its own target: the peer
    /// target leaves the board as it was before and records nothing.
    @Test @MainActor func aTargetHandledElsewhereLeavesNoStateAndNoNotice() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let target = fixture.target("vm", build: Self.older, outcomes: [.handledElsewhere])
        let board = DaemonUpdateBoard()
        board.showNotice = { _ in Issue.record("no notice") }
        let apply: @Sendable (DaemonUpdateEvent) async -> Void = { event in await MainActor.run { board.apply(event) } }
        await fixture.policy([target], board: apply).run()
        #expect(fixture.ledger.targets.isEmpty)
        #expect(board.targets["vm"] == nil)
    }

    /// A Cloud machine whose daemon the app refused: its build is unknown, and it loses nothing
    /// by updating at once. Urgent, it is updated first; a target of unknown build that is not
    /// urgent is still left alone.
    @Test func anUrgentTargetNeedsNoKnownBuildAndGoesFirst() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let busy = fixture.target("busy", build: Self.older, outcomes: [.busy, .updated(build: nil)])
        let unknown = fixture.target("unknown", build: nil, outcomes: [.updated(build: nil)])
        let refused = fixture.target("refused", build: nil, urgent: true, outcomes: [.updated(build: Self.bundled)])
        await fixture.policy([busy, unknown, refused], clock: clock).run()

        #expect(fixture.calls == ["refused", "busy", "busy"])
        #expect(clock.sleeps == [.seconds(120)])
        #expect(!fixture.overlapped)
        #expect(fixture.ledger.targets == ["refused": "updated", "busy": "updated"])
    }

    /// An urgent target offered while another waits out its busy backoff goes at once, not after
    /// the wait; the busy one is asked again after its backoff, never forced.
    @Test func anUrgentTargetDoesNotWaitBehindABusyOne() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = FirstSleepHeldClock()
        let busy = fixture.target("busy", build: Self.older, outcomes: [.busy, .updated(build: nil)])
        let refused = fixture.target("refused", build: nil, urgent: true, outcomes: [.updated(build: nil)])
        let policy = fixture.policy([], clock: clock)
        await policy.offer(busy)
        await clock.sleeping.wait()
        await policy.offer(refused)
        await policy.drained()

        #expect(fixture.calls == ["busy", "refused", "busy"])
        #expect(clock.sleeps == [.seconds(120), .seconds(120)])
        #expect(!fixture.overlapped)
        #expect(fixture.states("busy") == [.updating, .waitingForIdle, .updating, .updated(build: "abc123def")])
    }

    /// One policy takes targets from every source while it runs: a target offered again while it
    /// updates or waits in the queue is not queued twice, and every update waits its turn.
    @Test func anOfferWhileRunningIsDedupedAndWaitsItsTurn() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let started = UpdateSignal()
        let release = UpdateSignal()
        let first = fixture.target("first", build: Self.older, outcomes: [.updated(build: nil)], started: started, release: release)
        let second = fixture.target("second", build: Self.older, outcomes: [.updated(build: nil)])
        let policy = fixture.policy([])
        await policy.offer(first)
        await started.wait()
        await policy.offer(first)
        await policy.offer(second)
        await policy.offer(second)
        release.fire()
        await policy.drained()

        #expect(fixture.calls == ["first", "second"])
        #expect(!fixture.overlapped, "two updates ran at once")
        #expect(fixture.ledger.targets == ["first": "updated", "second": "updated"])

        // Offered again after its update: the ledger keeps it from a second attempt on this build.
        await policy.offer(first)
        await policy.drained()
        #expect(fixture.calls == ["first", "second"])
    }

    @Test func toggleOffRunsNothing() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let old = fixture.target("old", build: Self.older, outcomes: [.updated(build: nil)])
        let policy = fixture.policy([old], enabled: false)
        await policy.run()
        await policy.offer(old)
        await policy.drained()
        #expect(fixture.calls.isEmpty)
        #expect(fixture.targetReads == 0)
    }

    @Test func toggleIsOnByDefaultAndInDebugSettings() {
        #expect(AgentPaneTunables.updatePeersAutomatically.defaultValue)
        #expect(AgentPaneTunables.all.contains { $0.key == AgentPaneTunables.updatePeersAutomatically.key })
    }

    @Test func buildCommitReadsHashAndDirtyOnly() throws {
        let clean = try #require(DaemonBuildCommit("ABC123DEF 2026-10-20"))
        #expect(clean.hash == "abc123def" && !clean.dirty)
        #expect(clean.sameCommit("abc123def0123456789abcdef0123456789abcd"))
        #expect(!clean.sameCommit("abc123dee0123456789abcdef0123456789abcd"))
        #expect(try #require(DaemonBuildCommit("abc123def+dirty.00ff00ff 2026-10-20")).dirty)
        #expect(DaemonBuildCommit("nogit 2026-10-20") == nil)
        #expect(DaemonBuildCommit(nil) == nil)
        #expect(DaemonBuildCommit("") == nil)
    }
}

/// A scratch state directory, fake targets that share one call log, and the policy's events.
nonisolated final class PolicyFixture: Sendable {
    let root: URL
    private let log = Mutex<(calls: [String], running: Int, overlapped: Bool, events: [DaemonUpdateEvent], targetReads: Int)>(
        ([], 0, false, [], 0))

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var calls: [String] { log.withLock { $0.calls } }
    var overlapped: Bool { log.withLock { $0.overlapped } }
    var events: [DaemonUpdateEvent] { log.withLock { $0.events } }
    var targetReads: Int { log.withLock { $0.targetReads } }
    var notices: [DaemonUpdateEvent] { events.filter(\.notify) }
    func states(_ id: String) -> [DaemonUpdateEvent.State] { events.filter { $0.id == id }.map(\.state) }
    var ledger: DaemonUpdateLedger {
        DaemonUpdateLedger.read(root, build: DaemonBuildCommit(DaemonUpdatePolicyTests.bundled)?.hash ?? "")
    }

    /// A target that runs `build` and answers `outcomes` in turn (the last one again after that).
    /// `started` fires when its update begins, which then waits for `release`.
    func target(_ id: String, build: String?, sshHost: String? = nil, urgent: Bool = false, outcomes: [DaemonUpdateOutcome] = [],
                started: UpdateSignal? = nil, release: UpdateSignal? = nil) -> FakeUpdateTarget {
        FakeUpdateTarget(id: id, build: build, sshHost: sshHost, urgent: urgent, outcomes: outcomes, fixture: self,
                         started: started, release: release)
    }

    func began(_ id: String) {
        log.withLock { log in
            log.calls.append(id)
            log.running += 1
            if log.running > 1 { log.overlapped = true }
        }
    }

    func ended() { log.withLock { $0.running -= 1 } }

    func policy(_ targets: [FakeUpdateTarget], bundled: String = DaemonUpdatePolicyTests.bundled, clock: any Clock<Duration> = PolicyTestClock(),
                enabled: Bool = true, board: (@Sendable (DaemonUpdateEvent) async -> Void)? = nil) -> DaemonUpdatePolicy {
        DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { bundled },
            targets: {
                self.log.withLock { $0.targetReads += 1 }
                return targets
            },
            enabled: { enabled },
            report: { event in
                self.log.withLock { $0.events.append(event) }
                await board?(event)
            },
            directory: root,
            clock: clock
        ))
    }
}

nonisolated final class FakeUpdateTarget: DaemonUpdateTarget {
    let id: String
    let sshHost: String?
    var displayName: String { id }
    private let isUrgent: Bool
    private let fixture: PolicyFixture
    private let started: UpdateSignal?
    private let release: UpdateSignal?
    private let state: Mutex<(build: String?, outcomes: [DaemonUpdateOutcome])>

    init(id: String, build: String?, sshHost: String?, urgent: Bool, outcomes: [DaemonUpdateOutcome], fixture: PolicyFixture,
         started: UpdateSignal?, release: UpdateSignal?) {
        self.id = id
        self.sshHost = sshHost
        isUrgent = urgent
        self.fixture = fixture
        self.started = started
        self.release = release
        state = Mutex((build, outcomes))
    }

    var urgent: Bool {
        get async { isUrgent }
    }

    func currentBuild() async -> String? { state.withLock { $0.build } }

    func update(to build: DaemonBuildCommit) async -> DaemonUpdateOutcome {
        fixture.began(id)
        started?.fire()
        await release?.wait()
        await Task.yield()
        defer { fixture.ended() }
        return state.withLock { state in
            let outcome = state.outcomes.count > 1 ? state.outcomes.removeFirst() : state.outcomes.first ?? .failed(reason: "no outcome")
            switch outcome {
            case .updated(let reported): state.build = reported ?? build.hash
            case .current: state.build = build.hash
            default: break
            }
            return outcome
        }
    }
}

/// A clock whose sleeps return at once and move its time to their deadline, recording each wait.
nonisolated final class PolicyTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.withLock { state in
            state.sleeps.append(deadline.offset - state.now)
            state.now = max(state.now, deadline.offset)
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// A one-shot signal: ``wait()`` returns once ``fire()`` ran, also when it ran before.
nonisolated final class UpdateSignal: Sendable {
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let fired = state.withLock { state -> Bool in
                if !state.fired { state.waiters.append(continuation) }
                return state.fired
            }
            if fired { continuation.resume() }
        }
    }
}

/// A clock whose first sleep lasts until it is cancelled (``sleeping`` fires when it begins) and
/// moves no time; later sleeps return at once and move its time to their deadline. Records each wait.
nonisolated final class FirstSleepHeldClock: Clock, Sendable {
    typealias Instant = PolicyTestClock.Instant

    let sleeping = UpdateSignal()
    private let woken = UpdateSignal()
    private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let first = state.withLock { state -> Bool in
            state.sleeps.append(deadline.offset - state.now)
            return state.sleeps.count == 1
        }
        if first {
            sleeping.fire()
            let woken = woken
            await withTaskCancellationHandler {
                await woken.wait()
            } onCancel: {
                woken.fire()
            }
            throw CancellationError()
        }
        state.withLock { $0.now = max($0.now, deadline.offset) }
        await Task.yield()
        try Task.checkCancellation()
    }
}
