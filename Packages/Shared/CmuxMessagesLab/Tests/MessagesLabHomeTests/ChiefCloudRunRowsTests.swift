import AppKit
import CmuxAgentQuestion
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Rows the real Cloud run got wrong: an answered question card stayed live with "Create", a
/// command that failed after Allow still read as a green "Allowed", and the result card had
/// no sign-in state and no way to stop the machine.
@MainActor @Suite struct ChiefCloudRunRowsTests {
    typealias Rows = ChiefRowsTests

    static let machine = AgentQuestion.Item(
        id: "machine", header: "Machine", prompt: "Create a cloud machine?",
        options: [AgentQuestion.Option(id: "4g", label: "4 GB"), AgentQuestion.Option(id: "8g", label: "8 GB")],
        allowsOther: false)

    static func question(_ state: AgentQuestion.State = .pending) -> AgentQuestion {
        AgentQuestion(id: "q-1", source: AgentQuestion.Source(harness: .chief, session: "sess", agentName: "Chief"),
                      items: [machine], state: state, submitLabel: "Create")
    }

    // MARK: Question receipt

    @Test func anAnsweredCardCollapsesToOneReceiptRow() {
        let answer = AgentQuestionAnswer(selections: ["machine": AgentQuestionAnswer.Selection(optionIDs: ["4g"])])
        let answered = Self.question(.answered(answer))
        #expect(QuestionCardRow.receipt(answered) == "Machine: 4 GB")
        let provider = QuestionCardRowProvider.shared
        let part = QuestionCardRow.part(answered)
        #expect(provider.layout(for: part) == .fullWidth)
        let size = provider.measure(part, maxWidth: 500)
        #expect(size.width == 500)
        #expect(size.height == QuestionCardRow.receiptHeight)
        // Still waiting: the card with its chips and Create.
        let pending = QuestionCardRow.part(Self.question())
        #expect(provider.layout(for: pending) == .bubbleIncoming)
        #expect(provider.measure(pending, maxWidth: 500).height > QuestionCardRow.receiptHeight + 20)
        #expect(QuestionCardRow.receipt(Self.question()) == nil)
    }

    @Test func aCardClosedByATypedReplySaysSoAndAnotherHarnessSaysCancelled() {
        #expect(QuestionCardRow.receipt(Self.question(.cancelled)) == CmuxStrings.questionAnsweredInChat)
        var claude = Self.question(.cancelled)
        claude.source = AgentQuestion.Source(harness: .claude, session: "sess")
        #expect(QuestionCardRow.receipt(claude) == CmuxStrings.questionCancelled)
    }

    // MARK: Allowed, then failed

    /// Claude Code titles a Bash call with its description; the card quotes the command. The
    /// receipt still folds into the row, and a failure shows as the failure, not "Allowed".
    @Test func anAllowedCallFoldsByItsCommandAndItsFailureWins() {
        let command = "git clone --depth 1 https://github.com/manaflow-ai/cmux work/readme-title"
        let approval = MessagePart.approval(ApprovalRef(request: "perm-1", prompt: "Run `\(command)`?",
                                                        options: ["Allow", "Deny"], decided: "Allow"))
        func row(_ status: WorkRef.Status) -> MessagePart {
            .work(WorkRef(session: "t1", title: "Clone the repo", status: status, preview: command))
        }
        let running = [Rows.item(1, [approval]), Rows.item(2, [row(.running)])]
        guard case let .head(calls, allowed)? = ChiefRows.roles(running).value(for: IdempotencyKey("k1")) else {
            Issue.record("the receipt did not fold into the run")
            return
        }
        #expect(allowed && calls.map(\.id) == ["t1"])
        #expect(ChiefRows.roles(running).value(for: IdempotencyKey("k2")) == .folded)

        let failed = [Rows.item(1, [approval]), Rows.item(2, [row(.failed)])]
        guard case let .head(_, failedAllowed)? = ChiefRows.roles(failed).value(for: IdempotencyKey("k1")) else {
            Issue.record("the receipt did not fold into the failed run")
            return
        }
        #expect(!failedAllowed)
        let tools = Rows.tools(Rows.message(failed[0], in: failed).parts.first)
        #expect(tools?.allowed == nil)
        #expect(tools?.state == .failed)
    }

    // MARK: Result card

    @Test func aSignInCardWaitsWithItsOwnStateAndProvisioningNeverWaits() {
        let work = WorkRef(session: "ws_1", host: "vm-1", title: "Codex needs sign-in on chief-dogfood-1", status: .waiting,
                           preview: "Open the workspace and choose Sign in with Device Code")
        guard let part = ChiefCloudRows.part(work, createdAt: Date()), let card = part.decode(ChiefCloudRows.Result.self) else {
            Issue.record("no result card")
            return
        }
        #expect(card.state == .waiting)
        #expect(ChiefCloudRows.statusText(card.state) == CmuxStrings.cloudStatusNeedsSignIn)
        let row = WorkRef(session: ChiefCloudRows.provisionPrefix + "p1", title: "Cloud machine", status: .waiting)
        #expect(ChiefCloudRows.part(row, createdAt: Date())?.decode(ChiefCloudRows.Provision.self)?.state == .running)
    }

    @Test func stopMachineAsksTheChiefWithTheNameAndTheID() {
        let text = CmuxStrings.cloudStopMachineRequest("chief-dogfood-1", "vm-794a")
        #expect(text.contains("chief-dogfood-1") && text.contains("vm-794a"))
        let view = ChiefResultCardView(frame: CGRect(x: 0, y: 0, width: 340, height: 160))
        let result = ChiefCloudRows.Result(title: "Codex is working", subtitle: nil, machine: "vm-794a", workspace: "ws_1",
                                           state: .running, name: "chief-dogfood-1")
        let context = CustomRowContext(ref: PartRef(messageId: "m1", partIndex: 0), size: view.bounds.size, layout: .bubbleIncoming,
                                       isFocused: false, isWindowKey: true, isDark: true, actions: nil)
        view.show(result, context: context)
        view.layout()
        let stop = view.subviews.compactMap { $0 as? ChiefOptionButton }.first { $0.accessibilityIdentifier() == "ChiefResultStopMachine" }
        #expect(stop?.isEnabled == true)
        #expect(stop?.isHidden == false)
        #expect(stop?.toolTip == "cmux vm pause vm-794a")
        let desktop = view.subviews.compactMap { $0 as? ChiefOptionButton }.first { $0.accessibilityIdentifier() == "ChiefResultOpenDesktop" }
        #expect(desktop?.isHidden == false)
        #expect(desktop?.toolTip == "cmux vm desktop vm-794a")
    }
}
