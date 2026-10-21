import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Cloud machine actions from the CLI, MCP, a script, a page or another client
/// act only on the machine they name (`--target machine:<id>`). Before, a run
/// with no target fell back to the machine the person's window showed, else the
/// only machine, so an agent's `cloud kill-machine --confirm true` could kill
/// the machine the person was looking at. A person's own gesture keeps the
/// fallback. A non-person run also gets its answer back as `action.run`'s
/// `result` (`cloud new-machine` answers with the new machine's id).
@MainActor @Suite(.serialized)
struct CloudCLITargetTests {
    static func fixture() -> (services: AppServices, context: AppActionContext, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-cli-\(UUID().uuidString.prefix(8))")
        return (services, AppActionContext(services: services), session)
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatIsNotThePersonsNeedsAMachineTarget(origin: ActionOrigin) {
        let f = Self.fixture()
        #expect(f.services.machines.cloud.count == 1, "the only machine is the old fallback")
        #expect(throws: ActionFailure(message: CloudStrings.noMachine)) {
            try CloudHandlers.machine(ActionInvocation(origin: origin), f.context)
        }
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatNamesItsMachineActsOnIt(origin: ActionOrigin) throws {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), origin: origin)
        #expect(try CloudHandlers.machine(invocation, f.context) === f.session)
    }

    @Test func aRunNamingAMachineThatIsNotThereIsNotFound() {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-gone"), origin: .cli)
        do {
            _ = try CloudHandlers.machine(invocation, f.context)
            Issue.record("a missing machine resolved")
        } catch let failure as ActionFailure {
            #expect(failure.isNotFound)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func thePersonsGestureKeepsTheOnlyMachineFallback() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.machine(ActionInvocation(origin: .user), f.context) === f.session)
    }

    @Test func newCloudWorkspaceKeepsTheFallbackForAnyCaller() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.machine(ActionInvocation(origin: .cli), f.context, fallsBack: true) === f.session)
    }

    // MARK: Results for non-person runs

    @Test func aCLIAnswerComesBackAsTheRunsResult() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.answer("test answer", ActionInvocation(origin: .cli), f.context) {
                CloudAnswer(title: "Title", text: "hello", fields: ["count": .int(2)])
            }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("the answer failed")
            return
        }
        #expect(fields["text"] == .string("hello"))
        #expect(fields["count"] == .int(2))
    }

    @Test func aRefusalInTheWorkReachesTheCallerAsOne() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("test refusal", f.context) { throw ActionFailure(message: CloudStrings.notConnected) }
        }
        let task = try #require(run.results.first)
        guard case .failure(let failure) = await task.value else {
            Issue.record("the refusal succeeded")
            return
        }
        #expect(failure.refusal == .unavailable)
        #expect(failure.message == CloudStrings.notConnected)
    }

    /// A nested run is built with the default user origin; the run it sits in
    /// (``ActionRunScope``) decides, so a composite action started from the CLI
    /// gets no fallback either.
    @Test func aNestedRunInsideACLIRunNeedsAMachineTarget() {
        let f = Self.fixture()
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            #expect(throws: ActionFailure(message: CloudStrings.noMachine)) {
                try CloudHandlers.machine(ActionInvocation(), f.context)
            }
        }
    }

    /// Slow work (a snapshot can take minutes) answers `pending` once
    /// `pendingAfter` passes, well inside `action.run`'s 40 s result deadline,
    /// and keeps running; it never holds the answer until the work ends.
    @Test(.timeLimit(.minutes(1)))
    func slowWorkAnswersPendingWhenItsWaitEnds() async throws {
        let f = Self.fixture()
        let clock = ContinuousClock()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("slow snapshot", f.context, pendingAfter: .milliseconds(100), pending: ["machine_id": .string("vm-slow")]) {
                // wakeup-allow: a test's stand-in for a snapshot that takes longer than the answer's wait
                try await Task.sleep(for: .seconds(8))
                return ["snapshot_id": .string("late")]
            }
        }
        let task = try #require(run.results.first)
        let started = clock.now
        guard case .success(let fields) = await task.value else {
            Issue.record("slow work failed")
            return
        }
        #expect(fields["pending"] == .bool(true))
        #expect(fields["machine_id"] == .string("vm-slow"))
        #expect(fields["snapshot_id"] == nil)
        #expect(started.duration(to: clock.now) < .seconds(5), "the answer waited for the work")
    }

    @Test func quickWorkAnswersWithItsResultBeforeTheWaitEnds() async throws {
        let f = Self.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("quick snapshot", f.context, pendingAfter: .seconds(20)) { ["snapshot_id": .string("snap-1")] }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("quick work failed")
            return
        }
        #expect(fields["snapshot_id"] == .string("snap-1"))
        #expect(fields["pending"] == nil)
    }

    @Test func newMachineAnswersWithTheMachineOnceTheServerReturnsIt() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creation.attach(f.session)
        guard case .success(let fields) = await task.value else {
            Issue.record("the create failed")
            return
        }
        #expect(fields["machine_id"] == .string(f.session.machineID))
        #expect(fields["target"] == .string("machine:\(f.session.machineID)"))
        #expect(fields["pending"] == nil)
        creations.remove(creation)
    }

    @Test func aSlowCreateAnswersPendingInsteadOfTimingOut() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context, wait: .milliseconds(50)) }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("a slow create failed")
            return
        }
        #expect(fields["pending"] == .bool(true))
        #expect(fields["creation_id"] == .string(creation.id.uuidString.lowercased()))
        creations.remove(creation)
    }

    @Test func aDeclinedCreateIsRefused() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creations.remove(creation)
        guard case .failure(let failure) = await task.value else {
            Issue.record("a declined create succeeded")
            return
        }
        #expect(failure.message == CloudStrings.createDeclined)
    }

    @Test func aFailedCreateSaysWhy() async throws {
        let f = Self.fixture()
        let creations = f.services.cloud.creations
        let creation = creations.begin(window: nil)
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context) }
        let task = try #require(run.results.first)
        creation.fail(ActionFailure(message: "quota"))
        guard case .failure(let failure) = await task.value else {
            Issue.record("a failed create succeeded")
            return
        }
        #expect(failure.message.contains("quota"))
        creations.remove(creation)
    }
}
