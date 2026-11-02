import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp

/// The automatic Cloud machine update (``CloudMachineUpdates``): a ``CloudMachineUpdateTarget`` run
/// by a `DaemonUpdatePolicy` over that one machine (the app offers it to the shared one),
/// against a fake machine: its daemon's build and level and the answers of `cmux link machine
/// update`. The production policy updates it mid-turn from the first ask, with no wait for idle.
/// No VM and no daemon; the CLI itself is covered
/// by the Rust suites (`link/machine_update.rs`) and Update Machine by `CloudMoveTests`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudMachineUpdateTargetTests {
    static let bundled = "abc123def456"
    static let older = "a9b104f3cb7d"

    /// The production default (Leo: "OUR SHIT IS HARDLY EVER GOING TO GO IDLE"): a machine where an
    /// agent works is updated on the first ask, with no wait; the new daemon adopts the terminals
    /// and chats it interrupted.
    @Test func aBusyMachineIsUpdatedAtOnce() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)

        #expect(machine.updates == 1)
        #expect(fixture.clock.sleeps.isEmpty)
        #expect(fixture.states == [.updating, .updated(build: Self.bundled)])
        #expect(machine.reconnects == 1, "the connection is pointed at the new daemon")
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "updated"])
        #expect(fixture.notices.isEmpty)
    }

    /// The CLI cannot update now (another update of the machine runs): busy, asked again after
    /// the policy's backoff, then updated. An update ignores `whileBusy`: there is no idle check.
    @Test func aMachineTheCLICannotUpdateNowIsAskedAgain() async throws {
        let busyCLI = CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_busy", error: "another update runs")
        let machine = FakeCloudMachine(build: Self.older, level: .limited,
                                       answers: [busyCLI, CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)

        #expect(machine.updates == 2)
        #expect(fixture.clock.sleeps == [.seconds(120)])
        #expect(fixture.states == [.updating, .retrying, .updating, .updated(build: Self.bundled)])
        #expect(machine.reconnects == 2)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "updated"])
    }

    /// A refused daemon can't connect, so nothing on it is in use through the app: it goes first,
    /// though its build is unknown.
    @Test func anIncompatibleMachineUpdatesRightAway() async throws {
        let machine = FakeCloudMachine(build: nil, level: .incompatible,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        #expect(await fixture.target(machine).currentBuild() == nil)
        #expect(await fixture.target(machine).urgent)
        await fixture.run(machine)

        #expect(machine.updates == 1)
        #expect(fixture.clock.sleeps.isEmpty)
        #expect(fixture.states == [.updating, .updated(build: Self.bundled)])
        #expect(machine.reconnects == 1, "the waiting connect is woken")
    }

    /// A machine with no daemon answer yet (neither connected nor refused) is left alone.
    @Test func aMachineThatHasNotAnsweredIsLeftAlone() async throws {
        let machine = FakeCloudMachine(build: nil, level: .limited)
        machine.disconnect()
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 0)
        #expect(fixture.states.isEmpty)
    }

    /// A rollback shows its state and one notice; the next connect's pass (the same build) does
    /// not run it again. A new app build does.
    @Test func aFailureShowsOnceAndIsNotRetriedInALoop() async throws {
        let rolledBack = CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_rolled_back",
                                             error: "the new daemon did not serve, so the machine runs its old build again")
        let machine = FakeCloudMachine(build: Self.older, level: .limited, answers: [rolledBack])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        await fixture.run(machine)
        await fixture.run(machine)

        #expect(machine.updates == 1)
        #expect(fixture.board.targets[CloudMachineUpdateTarget.id("vm-1")]?.state == .failed(reason: rolledBack.error ?? "", rolledBack: true))
        #expect(fixture.notices.count == 1)
        #expect(fixture.notices.first?.contains("Leo VM") == true)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "rolledBack"])

        await fixture.run(machine, bundled: "fedcba987654")
        #expect(machine.updates == 2, "the app's next build tries once more")
    }

    /// Leo's screen: "lofty-lemon-stoat runs a cmux too old to update in place. Use a new Cloud
    /// machine instead." as a toast on every nightly, for any machine that answers
    /// `machine_update_unsupported`. Now no toast and no failure: the machine's line says what
    /// still works, and it is not asked again on a later build while it runs the same build. Once
    /// it serves everything this app uses (repaired), its line goes, in the same run.
    @Test func aMachineTooOldToUpdateHasNoToastIsNotAskedEachBuildAndClearsOnceRepaired() async throws {
        let unsupported = CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unsupported", error: "too old to update in place")
        let machine = FakeCloudMachine(build: Self.older, level: .limited, answers: [unsupported])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let id = CloudMachineUpdateTarget.id("vm-1")
        await fixture.run(machine)
        await fixture.run(machine, bundled: "fedcba987654")

        #expect(machine.updates == 1, "asked again on a later build")
        #expect(fixture.notices.isEmpty, "a toast for a machine too old to update in place")
        #expect(fixture.board.targets[id]?.state == .cannotUpdate(reason: CloudMachineUpdateStrings.unsupported("Leo VM")))
        #expect(fixture.board.otherMachines?.lines == [CloudMachineUpdateStrings.unsupported("Leo VM")])

        // Repaired: it serves everything this app uses, and its line goes at its next offer.
        let policy = fixture.policy(machine, bundled: "fedcba987654")
        machine.repair(build: "fedcba987654")
        await policy.offer(fixture.target(machine))
        await policy.drained()
        #expect(fixture.board.targets[id] == nil, "a repaired machine still says it cannot update")
        #expect(fixture.board.otherMachines == nil)
        #expect(machine.updates == 1)
    }

    /// `cloud.updateMachines` off: the machine reports no build and is not urgent, so the policy runs
    /// nothing, also for a machine it queued before. The shared store is set back before any await,
    /// so another suite's target never reads it off.
    @Test func theToggleOffMeansNoAutomaticUpdate() async throws {
        do {
            let store = TunableStore.shared
            store.activate(file: nil)
            store.register(CloudTunables.all)
            let key = CloudTunables.updateCloudMachinesAutomatically.key
            let previous = store.override(key)
            defer { store.set(key, previous) }
            store.set(key, nil)
            #expect(CloudTunables.updateCloudMachinesAutomatically.value, "on by default")
            store.set(key, .bool(false))
            #expect(!CloudTunables.updatesCloudMachines)
        }

        let machine = FakeCloudMachine(build: Self.older, level: .incompatible,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine, enabled: { false })
        #expect(machine.updates == 0)
        #expect(fixture.states.isEmpty)
    }

    /// Each `link machine update` answer (cmux-tui `link/machine_update.rs`) as the policy's outcome.
    @Test func cliAnswersMapToOutcomes() {
        func outcome(_ code: String?, ok: Bool = false, updated: Bool = false, build: String? = nil, error: String? = "why") -> DaemonUpdateOutcome {
            CloudMachineUpdateTarget.outcome(CloudMoveCLI.Answer(ok: ok, errorCode: code, error: error, updated: updated, build: build), machine: "Leo VM")
        }
        #expect(outcome(nil, ok: true, updated: true, build: Self.bundled) == .updated(build: Self.bundled))
        #expect(outcome(nil, ok: true) == .current)
        // `--if-older`: the machine runs a newer build (or the same tree); left alone, not recorded.
        let notOlder = CloudMoveCLI.Answer(ok: true, updated: false, build: Self.older, notOlder: true)
        #expect(CloudMachineUpdateTarget.outcome(notOlder, machine: "Leo VM") == .handledElsewhere)
        #expect(DaemonUpdatePolicy.recorded(.handledElsewhere) == nil)
        #expect(!CloudMachineUpdateTarget.mayHaveRestarted(notOlder))
        #expect(outcome("machine_update_busy") == .busy)
        #expect(outcome("machine_unreachable") == .busy)
        #expect(outcome("machine_update_unavailable") == .needsBinary(target: CloudMachineUpdateTarget.cloudTarget))
        #expect(outcome("machine_update_download_failed") == .needsBinary(target: CloudMachineUpdateTarget.cloudTarget))
        // Too old to update in place: no failure (no toast), and its words say what still works,
        // never "use a new Cloud machine".
        #expect(outcome("machine_update_unsupported") == .unsupported(reason: CloudMachineUpdateStrings.unsupported("Leo VM")))
        #expect(CloudMachineUpdateStrings.unsupported("Leo VM").contains("keep working"))
        #expect(!CloudMachineUpdateStrings.unsupported("Leo VM").contains("new Cloud machine"))
        #expect(outcome("machine_update_rolled_back") == .rolledBack(reason: "why"))
        #expect(outcome("machine_update_pending") == .failed(reason: "why"))
        #expect(outcome("machine_update_unresolved") == .busy, "the CLI lost the machine before the outcome: asked again")
        #expect(outcome(CloudMoveCLI.badAnswer, error: nil) == .failed(reason: CloudMoveCLI.badAnswer))
        // Not final: nothing recorded, so a later connect or launch asks again.
        #expect(DaemonUpdatePolicy.recorded(outcome("machine_update_unavailable")) == nil)
        #expect(DaemonUpdatePolicy.recorded(outcome("machine_update_unsupported")) == "unsupported")
    }

    /// A machine that serves every capability this app uses but runs an older build is updated
    /// too (2026-10-27: a VM on 8b3b1891 served everything, so no app update ever reached it and
    /// the app's ledger had no `cloud:` entry). The CLI's `--if-older` decides older.
    @Test func aMachineThatServesEverythingOnAnOlderBuildIsUpdated() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .current,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 1)
        #expect(fixture.states == [.updating, .updated(build: Self.bundled)])
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "updated"])
    }

    /// A machine on a newer build than this app's (`not_older` from `--if-older`) is never moved
    /// back: nothing changes, nothing is recorded, and its line goes.
    @Test func aMachineOnANewerBuildIsLeftAlone() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .current,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: false, build: Self.older, notOlder: true)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 1)
        #expect(machine.reconnectRestarts == [false], "the connection is left as it is")
        #expect(fixture.states == [.updating, .cleared])
        #expect(fixture.ledger.targets.isEmpty)
        #expect(fixture.notices.isEmpty)
    }

    /// A toggle turned off after the policy read the machine: the CLI does not run.
    @Test func aToggleTurnedOffBeforeTheCLIRunsStopsTheUpdate() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        let bundled = try #require(DaemonBuildCommit(Self.bundled))
        var target = fixture.target(machine)
        #expect(await target.currentBuild() == Self.older, "on when the policy reads the machine")
        target.enabled = { false }
        #expect(await target.update(to: bundled, whileBusy: false) == .busy)
        #expect(machine.updates == 0)
    }

    /// The CLI ran past its deadline: unknown, not a failure; asked again, then updated.
    @Test func aCLITimeoutIsAskedAgain() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited, timeouts: 1,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 2)
        #expect(fixture.notices.isEmpty)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "updated"])
    }

    /// An update that reports another build than the one it was to: a failure, not an update.
    @Test func anUpdateToAnotherBuildIsAFailure() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: "0123456789ab")])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(fixture.notices.count == 1)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "failed"])
    }

    /// A `link machine update` success line must carry its outcome and exit 0; `{"ok":true}` alone,
    /// or a success with a failing exit, is no answer, never "the machine needed nothing".
    @Test func aSuccessLineWithoutItsOutcomeIsNoAnswer() {
        func answer(_ object: [String: Any], status: Int32 = 0) -> CloudMoveCLI.Answer {
            let ok = object["ok"] as? Bool ?? false
            let parsed = CloudMoveCLI.Answer(ok: ok, errorCode: object["error_code"] as? String, updated: object["updated"] as? Bool ?? false,
                                             build: object["build"] as? String)
            return CloudMoveCLI.machineUpdateAnswer(parsed, object: object, status: status)
        }
        #expect(answer(["ok": true]).errorCode == CloudMoveCLI.badAnswer)
        #expect(answer(["ok": true, "updated": "yes"]).errorCode == CloudMoveCLI.badAnswer)
        #expect(answer(["ok": true, "updated": true]).errorCode == CloudMoveCLI.badAnswer, "updated with no build")
        #expect(answer(["ok": true, "updated": true, "build": Self.bundled], status: 1).errorCode == CloudMoveCLI.badAnswer)
        #expect(answer(["ok": true, "updated": true, "build": Self.bundled]) == CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled))
        #expect(answer(["ok": true, "updated": false, "build": Self.older]).ok)
        #expect(answer(["ok": false, "error_code": "machine_update_busy"], status: 1).errorCode == "machine_update_busy")
    }

    /// The CLI did not run to its answer (a kill, a crash): a failure, recorded once.
    @Test func aCLIErrorIsAFailure() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited, answers: [])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 1)
        #expect(fixture.notices.count == 1)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "failed"])
    }

    /// The header shows the update's line while it runs or retries; a failure stays until the machine is current.
    @Test func theHeaderShowsTheUpdateState() throws {
        let limited = "This machine runs cmux-tui 0.1.0 (a9b104f3cb7d). Update it to turn on every feature of this app."
        let event = { (state: DaemonUpdateEvent.State) in DaemonUpdateEvent(id: "cloud:vm-1", displayName: "Leo VM", state: state) }
        #expect(CloudCreationRows.withUpdate(limited, nil, compatibility: nil) == limited)
        #expect(CloudCreationRows.withUpdate(limited, event(.updating), compatibility: nil) == DaemonUpdateBoard.line(.updating))
        #expect(CloudCreationRows.withUpdate(limited, event(.retrying), compatibility: nil) == DaemonUpdateBoard.line(.retrying))
        let failed = DaemonUpdateEvent.State.failed(reason: "disk full", rolledBack: false)
        #expect(CloudCreationRows.withUpdate(limited, event(failed), compatibility: nil) == limited + "\n" + DaemonUpdateBoard.line(failed))
        #expect(CloudCreationRows.withUpdate(nil, event(.updated(build: Self.bundled)), compatibility: nil) == DaemonUpdateBoard.line(.updated(build: Self.bundled)))
        // One that cannot update in place: what still works, instead of "Update it".
        let cannot = DaemonUpdateEvent.State.cannotUpdate(reason: CloudMachineUpdateStrings.unsupported("Leo VM"))
        #expect(CloudCreationRows.withUpdate(limited, event(cannot), compatibility: nil) == CloudMachineUpdateStrings.unsupported("Leo VM"))

        // A failure stays while the machine runs another build than the update's, also one that
        // serves every capability; it goes once the machine runs that build.
        var running = try #require(DaemonCompatibility(refusal: .unsupportedProtocol(11)))
        running.level = .current
        running.buildCommit = Self.older
        var failure = event(failed)
        failure.build = try #require(DaemonBuildCommit(Self.bundled)).hash
        #expect(CloudCreationRows.withUpdate(nil, failure, compatibility: running) == DaemonUpdateBoard.line(failed),
                "an older build that serves every capability still shows the failure")
        running.buildCommit = Self.bundled + "0123456789abcdef0123456789"
        #expect(CloudCreationRows.withUpdate(nil, failure, compatibility: running) == nil, "the machine reached the build")
    }
}

/// A Cloud machine as the target sees it, shared with its closures.
nonisolated final class FakeCloudMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var daemon: CloudMachineUpdateTarget.Daemon?
    /// Each update takes the next; none left throws, as a CLI that did not answer.
    private var answers: [CloudMoveCLI.Answer]
    /// The first this many updates run past the CLI's deadline.
    private var timeouts: Int
    /// What each update through the Cloud API's exec answers (``CloudLegacyMachineUpdate``); nil:
    /// the machine has no exec, so it has none.
    private var legacyAnswers: [CloudMoveCLI.Answer]?
    private var counts = (updates: 0, reconnects: 0, legacy: 0)
    private var judgedBuilds: [String] = []
    private var restarts: [Bool] = []

    init(build: String?, level: DaemonCompatibility.Level, timeouts: Int = 0, answers: [CloudMoveCLI.Answer] = [],
         legacy: [CloudMoveCLI.Answer]? = nil) {
        daemon = CloudMachineUpdateTarget.Daemon(build: build, level: level)
        self.timeouts = timeouts
        self.answers = answers
        legacyAnswers = legacy
    }

    var updates: Int { lock.withLock { counts.updates } }
    var reconnects: Int { lock.withLock { counts.reconnects } }
    var legacyUpdates: Int { lock.withLock { counts.legacy } }
    /// The build the CLI judged older, as each exec update got it.
    var legacyJudged: [String] { lock.withLock { judgedBuilds } }
    /// Each reconnect's `restarted`.
    var reconnectRestarts: [Bool] { lock.withLock { restarts } }

    func disconnect() { lock.withLock { daemon = nil } }

    /// The machine gets the Cloud API's exec (or this app a pinned build): updates through it answer `answers`.
    func allowLegacy(_ answers: [CloudMoveCLI.Answer]) { lock.withLock { legacyAnswers = answers } }

    /// The machine was reinstalled by hand: it now serves everything this app uses.
    func repair(build: String) { lock.withLock { daemon = CloudMachineUpdateTarget.Daemon(build: build, level: .current) } }

    struct NoAnswer: Error {}

    var source: CloudMachineUpdateTarget.Source {
        CloudMachineUpdateTarget.Source(
            daemon: { self.lock.withLock { self.daemon } },
            update: {
                try self.lock.withLock {
                    self.counts.updates += 1
                    if self.timeouts > 0 {
                        self.timeouts -= 1
                        throw DaemonError.timedOut("cmux link machine update")
                    }
                    guard !self.answers.isEmpty else { throw NoAnswer() }
                    let answer = self.answers.removeFirst()
                    if answer.ok, let build = answer.build { self.daemon = CloudMachineUpdateTarget.Daemon(build: build, level: .current) }
                    return answer
                }
            },
            reconnect: { restarted in
                self.lock.withLock {
                    self.counts.reconnects += 1
                    self.restarts.append(restarted)
                }
            },
            legacy: { _, judged in
                self.lock.withLock {
                    guard var answers = self.legacyAnswers else { return nil }
                    self.counts.legacy += 1
                    self.judgedBuilds.append(judged)
                    guard !answers.isEmpty else { return CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unresolved") }
                    let answer = answers.removeFirst()
                    self.legacyAnswers = answers
                    if answer.ok, let build = answer.build { self.daemon = CloudMachineUpdateTarget.Daemon(build: build, level: .current) }
                    return answer
                }
            })
    }
}

/// A policy over one machine, as the shared one runs it, with a temporary ledger, a recording clock and its
/// own board.
@MainActor
final class CloudUpdateFixture {
    let root: URL
    let clock = CloudUpdateTestClock()
    let board = DaemonUpdateBoard()
    private(set) var events: [DaemonUpdateEvent] = []
    private(set) var notices: [String] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board.showNotice = { [weak self] in self?.notices.append($0.toast.message); return nil }
    }

    var directory: URL { root }
    var states: [DaemonUpdateEvent.State] { events.map(\.state) }
    var ledger: DaemonUpdateLedger { DaemonUpdateLedger.read(directory, build: DaemonBuildCommit(CloudMachineUpdateTargetTests.bundled)?.hash ?? "") }

    /// The target of `machine`, its toggles on unless `enabled` says otherwise (never the shared store).
    func target(_ machine: FakeCloudMachine, enabled: @escaping @Sendable () -> Bool = { true }) -> CloudMachineUpdateTarget {
        CloudMachineUpdateTarget(machineID: "vm-1", displayName: "Leo VM", source: machine.source, enabled: enabled)
    }

    /// The production policy's defaults, over `machine` only.
    func run(_ machine: FakeCloudMachine, bundled: String = CloudMachineUpdateTargetTests.bundled,
             enabled: @escaping @Sendable () -> Bool = { true }) async {
        await policy(machine, bundled: bundled, enabled: enabled).run()
    }

    /// A policy over `machine` only, to run or to offer the machine to.
    func policy(_ machine: FakeCloudMachine, bundled: String = CloudMachineUpdateTargetTests.bundled,
                enabled: @escaping @Sendable () -> Bool = { true }) -> DaemonUpdatePolicy {
        let target = target(machine, enabled: enabled)
        let dependencies = DaemonUpdatePolicy.Dependencies(
            bundledBuild: { bundled }, targets: { [target] }, enabled: { true },
            report: { [weak self] event in await self?.record(event) }, directory: directory, clock: clock)
        return DaemonUpdatePolicy(dependencies)
    }

    private func record(_ event: DaemonUpdateEvent) {
        events.append(event)
        board.apply(event)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A clock whose sleeps return at once and move its time, recording each one.
nonisolated final class CloudUpdateTestClock: Clock, @unchecked Sendable {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var slept: [Duration] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeps: [Duration] { lock.withLock { slept } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        lock.withLock {
            slept.append(current.duration(to: deadline))
            if current < deadline { current = deadline }
        }
    }
}
