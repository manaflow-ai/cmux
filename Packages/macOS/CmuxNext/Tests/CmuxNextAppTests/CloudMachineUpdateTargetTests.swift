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

    /// `cloud.updateMachines` off: the machine reports no build and is not urgent, so the policy runs
    /// nothing, also for a machine it queued before.
    @Test func theToggleOffMeansNoAutomaticUpdate() async throws {
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

        let machine = FakeCloudMachine(build: Self.older, level: .incompatible,
                                       answers: [CloudMoveCLI.Answer(ok: true, updated: true, build: Self.bundled)])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
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
        #expect(outcome("machine_update_busy") == .busy)
        #expect(outcome("machine_unreachable") == .busy)
        #expect(outcome("machine_update_unavailable") == .needsBinary(target: CloudMachineUpdateTarget.cloudTarget))
        #expect(outcome("machine_update_download_failed") == .needsBinary(target: CloudMachineUpdateTarget.cloudTarget))
        #expect(outcome("machine_update_unsupported") == .failed(reason: CloudMachineUpdateStrings.unsupported("Leo VM")))
        #expect(outcome("machine_update_rolled_back") == .rolledBack(reason: "why"))
        #expect(outcome("machine_update_pending") == .failed(reason: "why"))
        #expect(outcome(CloudMoveCLI.badAnswer, error: nil) == .failed(reason: CloudMoveCLI.badAnswer))
        // Not final: nothing recorded, so a later connect or launch asks again.
        #expect(DaemonUpdatePolicy.recorded(outcome("machine_update_unavailable")) == nil)
        #expect(DaemonUpdatePolicy.recorded(outcome("machine_update_unsupported")) == "failed")
    }

    /// The CLI did not run to its answer (a timeout, a kill): a failure, recorded once.
    @Test func aCLIErrorIsAFailure() async throws {
        let machine = FakeCloudMachine(build: Self.older, level: .limited, answers: [])
        let fixture = try CloudUpdateFixture()
        defer { fixture.remove() }
        await fixture.run(machine)
        #expect(machine.updates == 1)
        #expect(fixture.notices.count == 1)
        #expect(fixture.ledger.targets == [CloudMachineUpdateTarget.id("vm-1"): "failed"])
    }
}

/// A Cloud machine as the target sees it, shared with its closures.
nonisolated final class FakeCloudMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var daemon: CloudMachineUpdateTarget.Daemon?
    /// Each update takes the next; none left throws, as a CLI that did not answer.
    private var answers: [CloudMoveCLI.Answer]
    private var counts = (updates: 0, reconnects: 0)

    init(build: String?, level: DaemonCompatibility.Level, answers: [CloudMoveCLI.Answer] = []) {
        daemon = CloudMachineUpdateTarget.Daemon(build: build, level: level)
        self.answers = answers
    }

    var updates: Int { lock.withLock { counts.updates } }
    var reconnects: Int { lock.withLock { counts.reconnects } }

    func disconnect() { lock.withLock { daemon = nil } }

    struct NoAnswer: Error {}

    var source: CloudMachineUpdateTarget.Source {
        CloudMachineUpdateTarget.Source(
            daemon: { self.lock.withLock { self.daemon } },
            update: {
                try self.lock.withLock {
                    self.counts.updates += 1
                    guard !self.answers.isEmpty else { throw NoAnswer() }
                    let answer = self.answers.removeFirst()
                    if answer.ok, let build = answer.build { self.daemon = CloudMachineUpdateTarget.Daemon(build: build, level: .current) }
                    return answer
                }
            },
            reconnect: { self.lock.withLock { self.counts.reconnects += 1 } })
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
        board.showNotice = { [weak self] in self?.notices.append($0) }
    }

    var directory: URL { root }
    var states: [DaemonUpdateEvent.State] { events.map(\.state) }
    var ledger: DaemonUpdateLedger { DaemonUpdateLedger.read(directory, build: DaemonBuildCommit(CloudMachineUpdateTargetTests.bundled)?.hash ?? "") }

    func target(_ machine: FakeCloudMachine) -> CloudMachineUpdateTarget {
        CloudMachineUpdateTarget(machineID: "vm-1", displayName: "Leo VM", source: machine.source)
    }

    /// The production policy's defaults, over `machine` only.
    func run(_ machine: FakeCloudMachine, bundled: String = CloudMachineUpdateTargetTests.bundled) async {
        let target = target(machine)
        let dependencies = DaemonUpdatePolicy.Dependencies(
            bundledBuild: { bundled }, targets: { [target] }, enabled: { true },
            report: { [weak self] event in await self?.record(event) }, directory: directory, clock: clock)
        await DaemonUpdatePolicy(dependencies).run()
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
