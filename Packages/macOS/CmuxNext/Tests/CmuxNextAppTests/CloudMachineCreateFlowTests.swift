@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

/// cx-t2rz: New Cloud Machine / New Cloud Workspace create through the Cloud
/// app server (`cloud.machine.create`, never `/api/vm`), and the person stays
/// in the loop of the G8 approval: no approval is answered without the
/// native confirmation click, an agent's create shows the sheet before
/// anything is sent, and every retry uses the same idempotency key.
@MainActor
struct CloudMachineCreateFlowTests {
    nonisolated final class Server: Sendable {
        struct Call: Sendable, Equatable {
            var op: String
            var args: JSONValue
            var key: String?
            var origin: AppsRunRequest.Origin
        }

        let calls = Mutex<[Call]>([])
        let answers: Mutex<[Result<JSONValue, CloudAppOpFailure>]>

        init(_ answers: [Result<JSONValue, CloudAppOpFailure>]) {
            self.answers = Mutex(answers)
        }

        var all: [Call] { calls.withLock { $0 } }

        var run: CloudAppOp {
            { op, args, key, origin in
                self.calls.withLock { $0.append(Call(op: op, args: args, key: key, origin: origin)) }
                let next = self.answers.withLock { $0.isEmpty ? .failure(CloudAppOpFailure(code: "test.exhausted", message: "")) : $0.removeFirst() }
                return try next.get()
            }
        }
    }

    final class Person {
        var prompts: [CloudMachineCreateFlow.Prompt] = []
        var approved: [String] = []
        var pauses: [Int] = []
        let clicks: Bool

        init(clicks: Bool) {
            self.clicks = clicks
        }
    }

    static let machine: JSONValue = .object(["machine": .object(["id": .string("vm_1"), "status": .string("provisioning"), "name": .string("box")])])

    static func pending(_ request: String? = "apr_1") -> Result<JSONValue, CloudAppOpFailure> {
        .failure(CloudAppOpFailure(code: "cmux.cloud.approval_pending", message: "waits",
                                   details: request.map { .object(["request": .string($0)]) }))
    }

    static func flow(_ server: Server, _ person: Person, retries: Int = 8) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(
            run: server.run,
            confirm: { prompt in
                person.prompts.append(prompt)
                return person.clicks
            },
            approve: { request in person.approved.append(request) },
            pause: { attempt in person.pauses.append(attempt) },
            newKey: { "key-1" },
            retries: retries
        )
    }

    @Test func aPersonsCreateGoesToTheAppServerWithOneKeyAndOriginUser() async throws {
        let server = Server([.success(Self.machine)])
        let person = Person(clicks: true)
        let record = try await Self.flow(server, person).create(name: "box", startedByPerson: true)
        #expect(record["id"] == .string("vm_1"))
        #expect(server.all == [Server.Call(op: "cloud.machine.create",
                                           args: .object(["name": .string("box"), "size": CloudMachineCreateFlow.defaultSize]),
                                           key: "key-1", origin: .user)])
        #expect(person.prompts.isEmpty)
        #expect(person.approved.isEmpty)
    }

    @Test func approvalPendingShowsTheSheetThenApprovesAndRetriesTheSameKey() async throws {
        let server = Server([Self.pending(), Self.pending(), .success(Self.machine)])
        let person = Person(clicks: true)
        let record = try await Self.flow(server, person).create(name: nil, startedByPerson: true)
        #expect(record["id"] == .string("vm_1"))
        #expect(person.prompts == [.approval(request: "apr_1")])
        #expect(person.approved == ["apr_1"])
        #expect(server.all.map(\.key) == ["key-1", "key-1", "key-1"])
        #expect(server.all.allSatisfy { $0.op == "cloud.machine.create" && $0.origin == .user })
        #expect(person.pauses == [1])
    }

    @Test func aDeclinedApprovalSheetAnswersNothingAndSendsNothingMore() async {
        let server = Server([Self.pending()])
        let person = Person(clicks: false)
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) {
            _ = try await Self.flow(server, person).create(name: nil, startedByPerson: true)
        }
        #expect(person.approved.isEmpty)
        #expect(server.all.count == 1)
    }

    /// An agent (CLI, MCP, script) cannot act as the person: the sheet comes
    /// first, and nothing is sent until a person clicks.
    @Test func anAgentCreateShowsTheSheetBeforeAnythingIsSent() async {
        let server = Server([.success(Self.machine)])
        let person = Person(clicks: false)
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) {
            _ = try await Self.flow(server, person).create(name: nil, startedByPerson: false)
        }
        #expect(person.prompts == [.agentRequest])
        #expect(server.all.isEmpty)
        #expect(person.approved.isEmpty)
    }

    /// The person's click on the agent's request is the confirmation of that
    /// one create: its approval is answered without a second sheet.
    @Test func aConfirmedAgentCreateApprovesWithTheSameClick() async throws {
        let server = Server([Self.pending("apr_2"), .success(Self.machine)])
        let person = Person(clicks: true)
        _ = try await Self.flow(server, person).create(name: nil, startedByPerson: false)
        #expect(person.prompts == [.agentRequest])
        #expect(person.approved == ["apr_2"])
        #expect(server.all.map(\.key) == ["key-1", "key-1"])
    }

    @Test func aPendingAnswerWithoutItsRequestIsNeverApproved() async {
        let server = Server([Self.pending(nil)])
        let person = Person(clicks: true)
        await #expect(throws: CloudMachineCreateFlow.Failure.noApprovalRequest) {
            _ = try await Self.flow(server, person).create(name: nil, startedByPerson: true)
        }
        #expect(person.prompts.isEmpty)
        #expect(person.approved.isEmpty)
    }

    @Test func aCreateStillHeldAfterTheRetriesStopsWithStillPending() async {
        let server = Server([Self.pending(), Self.pending(), Self.pending(), Self.pending()])
        let person = Person(clicks: true)
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "apr_1")) {
            _ = try await Self.flow(server, person, retries: 2).create(name: nil, startedByPerson: true)
        }
        #expect(person.approved == ["apr_1"])
        #expect(server.all.count == 3)
    }

    @Test func otherRefusalsPassThroughUnanswered() async {
        let quota = CloudAppOpFailure(code: "cmux.cloud.quota_exceeded", message: "limit", details: .object(["limit": .number(1)]))
        let server = Server([.failure(quota)])
        let person = Person(clicks: true)
        await #expect(throws: quota) {
            _ = try await Self.flow(server, person).create(name: nil, startedByPerson: true)
        }
        #expect(person.prompts.isEmpty)
    }

    @Test func aBackendMachineMapsToTheSidebarRecord() throws {
        let machine = try #require(CloudMachine(next: .object(["id": .string("vm_9"), "status": .string("starting"), "name": .string("dev")])))
        #expect(machine.id == "vm_9")
        #expect(machine.status == .provisioning)
        #expect(machine.title == "dev")
        #expect(CloudMachine(next: .object(["status": .string("running")])) == nil)
        #expect(CloudMachine(next: .object(["id": .string("vm_8"), "status": .string("paused")]))?.status == .paused)
    }

    @Test func theApprovalItemIsTheOneCarryingTheRequest() {
        let item = { (id: String, request: String) -> [String: Any] in
            ["id": id, "prompt": ["action": ["input": ["approval": ["request": request, "team": "t", "digest": "d"]]]]]
        }
        let reply: [String: Any] = ["value": ["items": [item("fd_1", "apr_other"), item("fd_2", "apr_1")]]]
        #expect(CloudApprovalAnswer.item(carrying: "apr_1", in: reply) == "fd_2")
        #expect(CloudApprovalAnswer.item(carrying: "apr_none", in: reply) == nil)
    }
}
