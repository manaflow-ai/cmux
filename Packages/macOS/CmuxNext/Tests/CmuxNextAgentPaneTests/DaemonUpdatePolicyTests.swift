import CmuxNextCompat
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ``DaemonUpdatePolicy`` against fake targets: which machines it updates, in what order, how it
/// asks again while one is busy or cannot update, what it records and what it reports. The
/// production default updates mid-turn from the first ask (Leo: "OUR SHIT IS HARDLY EVER GOING TO
/// GO IDLE ... IT RESUMES WHATEVER IT INTERRUPTED. END OF STORY FOR THE DAEMON UPDATE.").
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

    /// Never a move back: a Linux host's own `acpmux-update.timer` keeps it on the newest
    /// feat-cmux-next build, often newer than this app's; updating it to the app's build would
    /// restart it twice for nothing (back, then forward at the timer's next run). A machine on a
    /// build with local changes is someone's own build. Both are left alone; one built earlier the
    /// same day as this app's, or with no date, is still updated.
    @Test func aTargetOnANewerOrItsOwnBuildIsLeftAlone() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let targets = [
            fixture.target("newer", build: "fedcba987 2026-10-21"),
            fixture.target("own", build: "0123456ff+dirty.00ff00ff 2026-10-01"),
            fixture.target("same-day", build: "0123456ff 2026-10-20", outcomes: [.updated(build: nil)]),
            fixture.target("no-date", build: "0123456ff", outcomes: [.updated(build: nil)]),
        ]
        await fixture.policy(targets).run()
        #expect(fixture.calls == ["same-day", "no-date"])
        #expect(fixture.states("newer").isEmpty && fixture.states("own").isEmpty)
        #expect(fixture.ledger.targets == ["same-day": "updated", "no-date": "updated"])
    }

    /// The production default: a machine where an agent works, whose idle update would answer
    /// busy, is updated mid-turn on the first ask, with no wait for a quiet moment, and ends on the
    /// build; the restarted daemon resumes the turn it interrupted.
    @Test func aBusyTargetIsUpdatedMidTurnOnTheFirstAsk() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let target = fixture.target("huge-blue", build: Self.older, outcomes: [.busy], whileBusy: .updated(build: nil))
        await fixture.policy([target], clock: clock).run()

        #expect(clock.sleeps.isEmpty)
        #expect(fixture.whileBusy == [true])
        #expect(await target.currentBuild() == "abc123def")
        #expect(fixture.states("huge-blue") == [.updating, .updated(build: "abc123def")])
        #expect(fixture.ledger.targets == ["huge-blue": "updated"])
        #expect(fixture.notices.isEmpty)
    }

    /// A target asked again that reached the build meanwhile (someone ran `host update` by hand)
    /// is not updated, and leaves the board instead of keeping "Update will try again soon".
    @Test func aRetriedTargetThatReachedTheBuildLeavesTheBoard() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let target = fixture.target("peer", build: Self.older, outcomes: [.busy])
        await fixture.policy([target], board: { event in
            if event.state == .retrying { target.reach(DaemonUpdatePolicyTests.bundled) }
        }).run()

        #expect(fixture.calls == ["peer"])
        #expect(fixture.states("peer") == [.updating, .retrying, .cleared])
        #expect(fixture.ledger.targets.isEmpty)
    }

    /// A machine that cannot update now, even mid-turn, is asked again after the backoff; the
    /// next one goes meanwhile. One at a time.
    @Test func targetsRunOneAtATimeAndABusyOneWaits() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let first = fixture.target("first", build: Self.older, outcomes: [.busy, .updated(build: nil)])
        let second = fixture.target("second", build: Self.older, outcomes: [.current])
        await fixture.policy([first, second], clock: clock).run()

        #expect(fixture.calls == ["first", "second", "first"])
        #expect(fixture.whileBusy == [true, true, true])
        #expect(clock.sleeps == [.seconds(120)])
        #expect(!fixture.overlapped, "two updates ran at once")
        #expect(fixture.states("first") == [.updating, .retrying, .updating, .updated(build: "abc123def")])
        #expect(fixture.ledger.targets == ["first": "updated", "second": "current"])
    }

    /// With a cap (`updateBusyAfter`, zero by default): a machine where a long-running agent always
    /// works never has an idle moment, so every idle update answers busy. The policy asks idle
    /// first (at 0, 2 and 6 minutes), then at the 10-minute cap updates it while busy, once, and it
    /// ends on the build: the wait for a quiet moment is bounded.
    @Test func withACapANeverIdleTargetIsUpdatedWhileBusyAtTheCap() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let target = fixture.target("huge-blue", build: Self.older, outcomes: [.busy], whileBusy: .updated(build: nil))
        await fixture.policy([target], clock: clock, updateBusyAfter: .seconds(600)).run()

        #expect(clock.sleeps == [.seconds(120), .seconds(240), .seconds(240)])
        #expect(clock.sleeps.reduce(.zero, +) == .seconds(600))
        #expect(fixture.whileBusy == [false, false, false, true])
        #expect(await target.currentBuild() == "abc123def")
        #expect(fixture.states("huge-blue") == [.updating, .retrying, .updating, .retrying, .updating, .retrying,
                                                .updating, .updated(build: "abc123def")])
        #expect(fixture.ledger.targets == ["huge-blue": "updated"])
        #expect(fixture.notices.isEmpty)
    }

    /// A target that answers busy also to an update while busy (unreachable, another update
    /// running) keeps the backoff (2, 4, 8, 16, then every 30 minutes) and is left for the next
    /// launch after six hours, unrecorded.
    @Test func aTargetBusyAlsoWhileBusyIsLeftAfterSixHours() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let clock = PolicyTestClock()
        let target = fixture.target("unreachable", build: Self.older, outcomes: [.busy])
        await fixture.policy([target], clock: clock).run()

        let minutes: [Int64] = [2, 4, 8, 16] + Array(repeating: 30, count: 11)
        #expect(clock.sleeps == minutes.map { .seconds($0 * 60) })
        #expect(fixture.whileBusy == Array(repeating: true, count: minutes.count + 1))
        #expect(await target.currentBuild() == Self.older)
        // Left: the board forgets it rather than promise a retry.
        #expect(fixture.states("unreachable").suffix(3) == [.retrying, .updating, .cleared])
        // Not recorded: the next launch tries again.
        #expect(fixture.ledger.targets.isEmpty)
        #expect(fixture.notices.isEmpty)
    }

    /// A failed update shows as failed on the board and asks for one notice, also when the app
    /// relaunches on the same build (the target is not tried again).
    @Test @MainActor func aFailureShowsItsStateAndAsksForOneNotice() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let board = DaemonUpdateBoard()
        let apply: @Sendable (DaemonUpdateEvent) async -> Void = { event in await MainActor.run { board.apply(event) } }
        let target = fixture.target("cmux16", build: Self.older, sshHost: "cmux16", outcomes: [.failed(reason: "disk full")])
        await fixture.policy([target], board: apply).run()
        await fixture.policy([target], board: apply).run()

        #expect(fixture.calls == ["cmux16"])
        #expect(board.targets["cmux16"]?.state == .failed(reason: "disk full", rolledBack: false))
        #expect(fixture.notices.map(\.id) == ["cmux16"])
    }

    /// A machine too old to update in place (Cloud `machine_update_unsupported`) is no failure: no
    /// notice, its line on the board, and it is not asked again on a later build of the app while
    /// it runs the same build (a nightly every half hour asked it, and toasted, every time). Once it
    /// runs another build (reinstalled), it is asked again.
    @Test func aMachineThatCannotUpdateInPlaceIsNotAskedOrToastedOnEveryBuild() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let reason = "old-vm runs a cmux too old to update in place. Its chats and terminals keep working."
        let target = fixture.target("old-vm", build: Self.older, outcomes: [.unsupported(reason: reason)])
        await fixture.policy([target]).run()
        await fixture.policy([target]).run()
        await fixture.policy([target], bundled: "fedcba987 2026-10-21").run()

        #expect(fixture.calls == ["old-vm"], "asked again on a later build")
        #expect(fixture.notices.isEmpty, "a toast for a machine that cannot update in place")
        #expect(fixture.states("old-vm") == [.updating, .cannotUpdate(reason: reason), .cannotUpdate(reason: reason), .cannotUpdate(reason: reason)])
        #expect(fixture.ledger.targets == ["old-vm": "unsupported"])

        target.reach("0123456aa 2026-10-05")
        await fixture.policy([target], bundled: "fedcba987 2026-10-21").run()
        #expect(fixture.calls == ["old-vm", "old-vm"])
    }

    /// Review of #25604: a machine reinstalled while the app runs is asked again at its next
    /// offer in the same run (the run's memory of it does not outlast its old build).
    @Test func aMachineReinstalledInTheSameRunIsAskedAgain() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let reason = "old-vm runs a cmux too old to update in place."
        let target = fixture.target("old-vm", build: Self.older, outcomes: [.unsupported(reason: reason), .updated(build: nil)])
        let policy = fixture.policy([target])
        await policy.run()
        await policy.offer(target)
        await policy.drained()
        #expect(fixture.calls == ["old-vm"])

        target.reach("0123456aa 2026-10-05")
        await policy.offer(target)
        await policy.drained()
        #expect(fixture.calls == ["old-vm", "old-vm"], "a reinstalled machine stayed skipped for the run")
        #expect(fixture.ledger.targets == ["old-vm": "updated"])
        #expect(fixture.ledger.cannotUpdate?["old-vm"] == nil)
    }

    /// Review of #25604: a machine whose build is unknown (a refused daemon) that cannot update is
    /// not kept as cannot-update across builds: nothing shows it is still the same machine, so the
    /// next build of the app asks it again (still without a toast).
    @Test func aMachineOfUnknownBuildThatCannotUpdateIsAskedOnTheNextBuild() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let reason = "refused runs a cmux too old to update in place."
        let target = fixture.target("refused", build: nil, urgent: true, outcomes: [.unsupported(reason: reason)])
        await fixture.policy([target]).run()
        #expect(fixture.ledger.cannotUpdate?["refused"] == nil)
        await fixture.policy([target]).run()
        #expect(fixture.calls == ["refused"])
        await fixture.policy([target], bundled: "fedcba987 2026-10-21").run()
        #expect(fixture.calls == ["refused", "refused"])
        #expect(fixture.notices.isEmpty)
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

    /// Review of #25387: the ledger can't be written (its directory is a file). The failure is
    /// still final for this build in this run: offered again, the target is not tried again.
    @Test func aFailureWhoseLedgerCannotBeWrittenIsNotRetried() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let blocked = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let target = fixture.target("cmux16", build: Self.older, outcomes: [.rolledBack(reason: "new daemon reported 0123456ff")])
        let policy = fixture.policy([target], directory: blocked)
        await policy.run()
        await policy.offer(target)
        await policy.drained()
        await policy.run()

        #expect(fixture.calls == ["cmux16"], "a rolled-back build was tried again because its ledger was not written")
        #expect(fixture.notices.count == 1)
    }

    /// Review of #25387: the bundled acpmux's `--version` never answers. The probe ends at its
    /// bound with no build, so the queue drains (pushes nothing) instead of waiting forever.
    @Test(.timeLimit(.minutes(1))) func aBundledVersionThatNeverAnswersEndsAtItsBound() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let hung = fixture.root.appendingPathComponent("acpmux")
        try "#!/bin/sh\nexec sleep 120\n".write(to: hung, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)
        let started = ContinuousClock.now
        #expect(await DaemonUpdatePolicy.bundledBuild(of: hung, within: .milliseconds(500)) == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// The probe reads the build from `acpmux --version`.
    @Test func theBundledVersionGivesTheBuild() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let acpmux = fixture.root.appendingPathComponent("acpmux")
        try "#!/bin/sh\necho 'acpmux 0.1.0 (abc123def 2026-10-20)'\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        #expect(await DaemonUpdatePolicy.bundledBuild(of: acpmux, within: .seconds(10)) == Self.bundled)
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
        let apply: @Sendable (DaemonUpdateEvent) async -> Void = { event in await MainActor.run { board.apply(event) } }
        await fixture.policy([target], board: apply).run()
        #expect(fixture.ledger.targets.isEmpty)
        #expect(fixture.notices.isEmpty)
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
    /// the wait; the busy one is asked again after its backoff.
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
        #expect(fixture.whileBusy == [true, true, true])
        #expect(clock.sleeps == [.seconds(120), .seconds(120)])
        #expect(!fixture.overlapped)
        #expect(fixture.states("busy") == [.updating, .retrying, .updating, .updated(build: "abc123def")])
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

    /// The toggle goes off while a target waits to be asked again, and back on while the policy
    /// reports that target cleared; a target offered during that report still updates, and the
    /// policy only counts as drained once it did.
    @Test func aTargetOfferedWhileTheToggleOffIsReportedStillUpdates() async throws {
        let fixture = try PolicyFixture()
        defer { fixture.remove() }
        let enabled = Mutex(true)
        let busy = fixture.target("busy", build: Self.older, outcomes: [.busy])
        let later = fixture.target("later", build: Self.older, outcomes: [.updated(build: nil)])
        let policy = Mutex<DaemonUpdatePolicy?>(nil)
        let made = fixture.policy([], isEnabled: { enabled.withLock { $0 } }, board: { event in
            switch event.state {
            case .retrying: enabled.withLock { $0 = false }
            case .cleared where event.id == "busy":
                enabled.withLock { $0 = true }
                await policy.withLock { $0 }?.offer(later)
            default: break
            }
        })
        policy.withLock { $0 = made }
        await made.offer(busy)
        await made.drained()

        #expect(fixture.calls == ["busy", "later"])
        #expect(fixture.states("busy") == [.updating, .retrying, .cleared])
        #expect(fixture.states("later") == [.updating, .updated(build: "abc123def")])
        #expect(fixture.ledger.targets == ["later": "updated"])
    }
}

/// A scratch state directory, fake targets that share one call log, and the policy's events.
nonisolated final class PolicyFixture: Sendable {
    let root: URL
    private let log = Mutex<(calls: [String], whileBusy: [Bool], running: Int, overlapped: Bool, events: [DaemonUpdateEvent],
                             targetReads: Int)>(([], [], 0, false, [], 0))

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var calls: [String] { log.withLock { $0.calls } }
    /// Each call's `whileBusy`, in the order of ``calls``.
    var whileBusy: [Bool] { log.withLock { $0.whileBusy } }
    var overlapped: Bool { log.withLock { $0.overlapped } }
    var events: [DaemonUpdateEvent] { log.withLock { $0.events } }
    var targetReads: Int { log.withLock { $0.targetReads } }
    var notices: [DaemonUpdateEvent] { events.filter(\.notify) }
    func states(_ id: String) -> [DaemonUpdateEvent.State] { events.filter { $0.id == id }.map(\.state) }
    var ledger: DaemonUpdateLedger {
        DaemonUpdateLedger.read(root, build: DaemonBuildCommit(DaemonUpdatePolicyTests.bundled)?.hash ?? "")
    }

    /// A target that runs `build` and answers `outcomes` in turn (the last one again after that).
    /// An update while busy answers `whileBusy` when given, else the next of `outcomes`.
    /// `started` fires when its update begins, which then waits for `release`.
    func target(_ id: String, build: String?, sshHost: String? = nil, urgent: Bool = false, outcomes: [DaemonUpdateOutcome] = [],
                whileBusy: DaemonUpdateOutcome? = nil, started: UpdateSignal? = nil, release: UpdateSignal? = nil) -> FakeUpdateTarget {
        FakeUpdateTarget(id: id, build: build, sshHost: sshHost, urgent: urgent, outcomes: outcomes, whileBusy: whileBusy, fixture: self,
                         started: started, release: release)
    }

    func began(_ id: String, whileBusy: Bool) {
        log.withLock { log in
            log.calls.append(id)
            log.whileBusy.append(whileBusy)
            log.running += 1
            if log.running > 1 { log.overlapped = true }
        }
    }

    func ended() { log.withLock { $0.running -= 1 } }

    /// `updateBusyAfter`: nil keeps the production default (``DaemonUpdatePolicy/Dependencies/updateBusyAfter``, zero: mid-turn at once).
    /// `isEnabled`, when given, is read at every step instead of `enabled`.
    func policy(_ targets: [FakeUpdateTarget], bundled: String = DaemonUpdatePolicyTests.bundled, clock: any Clock<Duration> = PolicyTestClock(),
                enabled: Bool = true, isEnabled: (@Sendable () -> Bool)? = nil,
                board: (@Sendable (DaemonUpdateEvent) async -> Void)? = nil,
                updateBusyAfter: Duration? = nil, directory: URL? = nil) -> DaemonUpdatePolicy {
        var dependencies = DaemonUpdatePolicy.Dependencies(
            bundledBuild: { bundled },
            targets: {
                self.log.withLock { $0.targetReads += 1 }
                return targets
            },
            enabled: isEnabled ?? { enabled },
            report: { event in
                self.log.withLock { $0.events.append(event) }
                await board?(event)
            },
            directory: directory ?? root,
            clock: clock
        )
        if let updateBusyAfter { dependencies.updateBusyAfter = updateBusyAfter }
        return DaemonUpdatePolicy(dependencies)
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
    private let whileBusyOutcome: DaemonUpdateOutcome?
    private let state: Mutex<(build: String?, outcomes: [DaemonUpdateOutcome])>

    init(id: String, build: String?, sshHost: String?, urgent: Bool, outcomes: [DaemonUpdateOutcome], whileBusy: DaemonUpdateOutcome?,
         fixture: PolicyFixture, started: UpdateSignal?, release: UpdateSignal?) {
        self.id = id
        self.sshHost = sshHost
        isUrgent = urgent
        whileBusyOutcome = whileBusy
        self.fixture = fixture
        self.started = started
        self.release = release
        state = Mutex((build, outcomes))
    }

    var urgent: Bool {
        get async { isUrgent }
    }

    func currentBuild() async -> String? { state.withLock { $0.build } }

    /// Moves the target to `build` outside the policy, as a hand-run update would.
    func reach(_ build: String) { state.withLock { $0.build = build } }

    func update(to build: DaemonBuildCommit, whileBusy: Bool) async -> DaemonUpdateOutcome {
        fixture.began(id, whileBusy: whileBusy)
        started?.fire()
        await release?.wait()
        await Task.yield()
        defer { fixture.ended() }
        let forced = whileBusy ? whileBusyOutcome : nil
        return state.withLock { state in
            let outcome = forced ?? (state.outcomes.count > 1 ? state.outcomes.removeFirst() : state.outcomes.first ?? .failed(reason: "no outcome"))
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
