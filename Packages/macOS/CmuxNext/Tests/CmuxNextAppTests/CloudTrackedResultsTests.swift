import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// Fork, restore, new-workspace, rename, kill and resize answer a CLI or agent
/// caller with the ids it names next, and a failure instead of OK. Before, they
/// ran untracked (`run`): the CLI heard OK at once and a failure was only a
/// sheet on the person's screen. The hints they and their neighbours give name
/// only verbs the CLI offers.
@MainActor
struct CloudTrackedResultsTests {
    nonisolated static let trackedIDs: [ActionID] = [
        "palette.cloud.fork", "palette.cloud.restore", "newCloudWorkspace",
        "cloudRenameMachine", "cloudKillMachine", "cloudResizeMachine",
    ]

    static func descriptor(_ id: ActionID) throws -> ActionDescriptor {
        try #require(ActionCatalog.all.first { $0.id == id }, "\(id)")
    }

    static func verbs(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "cmux cloud ([a-z-]+)")
        let range = NSRange(text.startIndex..., in: text)
        return (pattern?.matches(in: text, range: range) ?? []).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    @Test(arguments: trackedIDs)
    func theCLIWaitsForTheResult(id: ActionID) throws {
        #expect(try Self.descriptor(id).waitsForResult)
    }

    @Test func newCloudWorkspaceTakesAMachineTarget() throws {
        #expect(try Self.descriptor("newCloudWorkspace").targets == [.machine])
    }

    /// The fields a machine action answers: its id and the target the next command passes.
    @Test func aMachineResultNamesTheMachineAndItsTarget() {
        let fields = CloudHandlers.machineFields("vm-2", ["source_machine_id": .string("vm-1")])
        #expect(fields["machine_id"] == .string("vm-2"))
        #expect(fields["target"] == .string("machine:vm-2"))
        #expect(fields["source_machine_id"] == .string("vm-1"))
        // An extra field never replaces the machine's own id.
        #expect(CloudHandlers.machineFields("vm-2", ["machine_id": .string("other")])["machine_id"] == .string("vm-2"))
    }

    @Test func aCLIRenameAnswersTheMachineAndName() async throws {
        let f = CloudCLITargetTests.fixture()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("rename machine", f.context) { CloudHandlers.machineFields(f.session.machineID, ["name": .string("lane")]) }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("the rename failed")
            return
        }
        #expect(fields["machine_id"] == .string(f.session.machineID))
        #expect(fields["name"] == .string("lane"))
    }

    /// 2026-11-11: an agent's `cmux vm fork` waited on the person's Allow sheet past the 30 s
    /// answer wait and answered a bare `pending` (`ran true`, `created []`); the sheet went when the
    /// app quit and nothing was made, with no word to anyone. Now the `pending` answer says it waits
    /// for the person, and a failure after it reaches the person as a notice.
    @Test(.timeLimit(.minutes(1)))
    func aForkWaitingOnTheAllowSheetSaysSoAndALaterFailureReachesThePerson() async throws {
        let f = CloudCLITargetTests.fixture()
        let (refusals, refused) = AsyncStream<String>.makeStream()
        f.services.registry.refusalObserver = { reason, _ in refused.yield(reason) }
        let (answers, answer) = AsyncStream<Bool>.makeStream()
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("fork machine", f.context, pendingAfter: .milliseconds(50), pending: ["source_machine_id": .string("vm-1")]) {
                let allowed = await CloudRunProgress.current?.asking("Fork Cloud Machine") {
                    for await yes in answers { return yes }
                    return false
                } ?? false
                guard allowed else { throw ActionFailure(message: "not allowed") }
                throw ActionFailure(message: "snapshot failed")
            }
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("the pending answer failed")
            return
        }
        #expect(fields["pending"] == .bool(true))
        #expect(fields["source_machine_id"] == .string("vm-1"))
        #expect(fields["awaiting"] == .string("allow"))
        #expect(fields["text"] == .string(CloudRunProgress.awaitingAllowText("Fork Cloud Machine")))
        answer.yield(true)
        var late: String?
        for await reason in refusals { late = reason; break }
        #expect(late == CloudRunProgress.lateFailureText("Fork Cloud Machine", "snapshot failed"))
    }

    /// Work that answers within the wait answers itself: no `pending`, nothing waiting, no notice.
    @Test func aRunThatAnswersInTimeIsNeitherPendingNorANotice() async throws {
        let f = CloudCLITargetTests.fixture()
        final class Seen { var refusals: [String] = [] }
        let seen = Seen()
        f.services.registry.refusalObserver = { reason, _ in seen.refusals.append(reason) }
        let run = f.services.registry.capturingRun {
            CloudHandlers.result("fork machine", f.context, pendingAfter: .seconds(30)) { throw ActionFailure(message: "snapshot failed") }
        }
        let task = try #require(run.results.first)
        guard case .failure(let failure) = await task.value else {
            Issue.record("the failure answered OK")
            return
        }
        #expect(failure.message == "snapshot failed")
        #expect(seen.refusals.isEmpty, "the caller hears this failure; the person gets no second notice")
    }

    /// The handoff text and the exec refusal name verbs a CLI can run: not
    /// `open-machine` or `machine-tools`, which are GUI-only and print `not_a_verb`.
    @Test func theHandoffAndExecHintsNameCLIVerbs() throws {
        let machine = CloudMachine(id: "vm-9", provider: "freestyle", status: .running)
        let texts = [CloudHandlers.handoff(machine), CloudStrings.execUnavailable("vm-9")]
        for text in texts {
            let verbs = Self.verbs(in: text)
            #expect(!verbs.isEmpty, "\(text)")
            for verb in verbs {
                let descriptor = ActionCatalog.all.first { $0.cliName == "cloud \(verb)" }
                #expect(descriptor?.cli == true, "`cmux cloud \(verb)` in “\(text)” is not a CLI verb")
                #expect(text.contains("cmux cloud \(verb) --target machine:vm-9"), "`cmux cloud \(verb)` names no machine in “\(text)”")
            }
        }
    }

    @Test func aTargetNamingNoMachineSaysSoAndHowToListThem() {
        let f = CloudCLITargetTests.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-gone"), origin: .cli)
        do {
            _ = try CloudHandlers.machine(invocation, f.context)
            Issue.record("a missing machine resolved")
        } catch let failure as ActionFailure {
            #expect(failure.isNotFound)
            #expect(failure.message == CloudStrings.unknownMachine("vm-gone"))
            #expect(Self.verbs(in: failure.message) == ["list-machines"])
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// `cloud new-workspace --target machine:<id>` with an id that is not
    /// there is refused with the unknown-machine text, not answered with a
    /// new machine; with no target it makes a new machine, never the only one.
    @Test func newWorkspaceOnAnUnknownMachineIsRefused() throws {
        let f = CloudCLITargetTests.fixture()
        let named = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-gone"), origin: .cli)
        #expect(throws: ActionFailure.notFound(CloudStrings.unknownMachine("vm-gone"))) {
            try CloudHandlers.workspaceMachine(named, f.context)
        }
        #expect(try CloudHandlers.workspaceMachine(ActionInvocation(origin: .cli), f.context) == nil)
        let mine = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), origin: .cli)
        #expect(try CloudHandlers.workspaceMachine(mine, f.context) === f.session)
    }

    @Test func anUnboundCloudActionSaysToUpdate() {
        #expect(!MiscHandlerStrings.cloud.contains("Cloud wave"))
        #expect(MiscHandlerStrings.cloud.contains("Update cmux"))
    }
}
