import CmuxAgentQuestion
@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// The owner's side of the Cloud setup flow: the question card and its
/// answer, one updating provisioning row, and the result card.
@Suite struct ChiefCloudFlowTests {
    let conversation = ChiefConversationOwner.defaultConversationID

    static let question = AgentQuestion(
        id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
        items: [AgentQuestion.Item(id: "machine", header: "Machine", prompt: "Create a cloud machine?",
                                   options: [AgentQuestion.Option(id: "8g", label: "8 GB", detail: "4 vCPU"),
                                             AgentQuestion.Option(id: "4g", label: "4 GB")],
                                   allowsOther: false)],
        submitLabel: "Create")

    @Test func questionIsPostedAndItsAnswerIsTheNextTurn() async throws {
        let brain = FakeBrain { request, continuation in
            if request.userText == "set up a machine" {
                continuation.yield(.textDelta("Here are the options."))
                continuation.yield(.question(Self.question))
            } else {
                continuation.yield(.textDelta("Creating it."))
                continuation.yield(.textSegmentEnd)
            }
            continuation.yield(.finished)
            continuation.finish()
        }
        let owner = try ChiefFixture().owner(brain)
        try await ChiefFixture.send("set up a machine", to: owner)
        let asked = try await ChiefFixture.idleMessages(owner, count: 3)
        // The text before the card commits as its own bubble, then the card.
        #expect(asked[1].plainText == "Here are the options.")
        guard case .question(let posted) = asked[2].parts.first else {
            Issue.record("expected a question part")
            return
        }
        #expect(posted.isPending && posted.submitLabel == "Create")

        let answer = AgentQuestionAnswer(selections: ["machine": AgentQuestionAnswer.Selection(optionIDs: ["4g"])])
        _ = try await owner.submit(HomeIntent(op: .answerQuestion(message: asked[2].id, conversation: conversation,
                                                                   partIndex: 0, answer: answer)))
        let after = try await ChiefFixture.idleMessages(owner, count: 4)
        guard case .question(let answered) = after[2].parts.first, case .answered(let stored) = answered.state else {
            Issue.record("expected the answered question")
            return
        }
        #expect(stored.selections["machine"]?.optionIDs == ["4g"])
        #expect(answered.submitLabel == "Create")
        #expect(after.last?.plainText == "Creating it.")
        let requests = await brain.log.requests
        #expect(requests.count == 2)
        #expect(requests.last?.userText.contains("Machine: 4 GB") == true)

        // A second answer is refused: the card is closed.
        await #expect(throws: HomeRejection.invalid("question_closed")) {
            _ = try await owner.submit(HomeIntent(op: .answerQuestion(message: asked[2].id, conversation: self.conversation,
                                                                       partIndex: 0, answer: answer)))
        }
    }

    @Test func provisioningCallsShareOneUpdatingRow() async throws {
        let owner = try ChiefFixture().owner(.events([
            .toolStarted(id: "t1", title: "Create machine", detail: "cmux vm new --detach --name api --size 8g --json"),
            .toolFinished(id: "t1", ok: true, preview: "{\n  \"id\" : \"brave-otter\","),
            .toolStarted(id: "t2", title: "Wait for it", detail: "cmux vm wait brave-otter --wake"),
            .toolFinished(id: "t2", ok: true, preview: "brave-otter is ready"),
            .toolStarted(id: "t3", title: "List machines", detail: "cmux vm ls --json"),
            .toolFinished(id: "t3", ok: true, preview: nil),
            .textDelta("Ready."), .textSegmentEnd, .finished,
        ]))
        let recorder = EventRecorder()
        await recorder.start(owner)
        try await ChiefFixture.send("create it", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 4)
        // One provisioning row, then the ordinary tool line, then the reply.
        #expect(messages.count == 4)
        guard case .work(let row) = messages[1].parts.first, case .work(let tool) = messages[2].parts.first else {
            Issue.record("expected work parts")
            return
        }
        #expect(ChiefCloudProvisioning.isProvisioning(row))
        #expect(row.title == ChiefCloudProvisioning.title && row.host == "brave-otter" && row.status == .done)
        // The row shows the machine's name (`--name api`); the id stays in `host` (Home's tooltip).
        #expect(row.preview == "api")
        #expect(!ChiefCloudProvisioning.isProvisioning(tool) && tool.session == "t3")

        _ = await ChiefFixture.eventually { await recorder.messages().filter { $0.id == messages[1].id }.count >= 4 }
        let statuses = await recorder.messages().filter { $0.id == messages[1].id }.compactMap { message -> WorkRef.Status? in
            if case .work(let work) = message.parts.first { return work.status }
            return nil
        }
        // Created (running), still running after `vm new`, running again for the wait, then ready.
        #expect(statuses.first == .running && statuses.last == .done)
        #expect(!statuses.dropLast().contains(.done))
    }

    @Test func theMachinesNameComesFromTheCommandOrTheOutput() {
        typealias Owner = ChiefConversationOwner
        #expect(Owner.machineName(inCommand: #"cmux vm new --detach --name "chief-dogfood-1" --size 4g --json"#) == "chief-dogfood-1")
        #expect(Owner.machineName(inCommand: "cmux vm new --name=api --json") == "api")
        #expect(Owner.machineName(inCommand: "cmux vm new --name --json") == nil)
        #expect(Owner.machineName(inCommand: "cmux vm wait vm-1 --wake") == nil)
        #expect(Owner.machineName(inOutput: "{\n  \"id\" : \"vm-1\",\n  \"name\" : \"chief-dogfood-1\"\n}") == "chief-dogfood-1")
        #expect(Owner.machineName(inOutput: "vm-1 is ready") == nil)
    }

    @Test func failedWaitFailsTheRow() async throws {
        let owner = try ChiefFixture().owner(.events([
            .toolStarted(id: "t1", title: "Create", detail: "cmux vm new --detach --json"),
            .toolFinished(id: "t1", ok: false, preview: "vm_requires_pro"),
            .finished,
        ]))
        try await ChiefFixture.send("create it", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        guard case .work(let row) = messages[1].parts.first else { Issue.record("expected the row"); return }
        #expect(row.status == .failed && row.preview == "vm_requires_pro")
    }

    @Test func failedWaitKeepsTheMachineName() async throws {
        let owner = try ChiefFixture().owner(.events([
            .toolStarted(id: "t1", title: "Create", detail: "cmux vm new --detach --name api --size 8g --json"),
            .toolFinished(id: "t1", ok: true, preview: #"{"id":"vm-1","displayName":"api"}"#),
            .toolStarted(id: "t2", title: "Wait", detail: "cmux vm wait vm-1"),
            .toolFinished(id: "t2", ok: false, preview: "network_error"),
            .finished,
        ]))
        try await ChiefFixture.send("create it", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 2)
        guard case .work(let row) = messages[1].parts.first else { Issue.record("expected the row"); return }
        #expect(row.status == .failed)
        #expect(row.preview == "api")
    }

    @Test func resultCardIsAHostedWorkPart() async throws {
        let card = ChiefResultCard(title: "Codex is working on brave-otter", subtitle: "fix login · ws_4f2c",
                                   machine: "brave-otter", workspace: "ws_4f2c", status: .working)
        let owner = try ChiefFixture().owner(.events([.result(card), .textDelta("It's running."), .textSegmentEnd, .finished]))
        try await ChiefFixture.send("go", to: owner)
        let messages = try await ChiefFixture.idleMessages(owner, count: 3)
        guard case .work(let work) = messages[1].parts.first else { Issue.record("expected the card"); return }
        #expect(work == WorkRef(session: "ws_4f2c", host: "brave-otter", title: "Codex is working on brave-otter",
                                status: .running, preview: "fix login · ws_4f2c"))
        #expect(messages[2].plainText == "It's running.")
    }
}
