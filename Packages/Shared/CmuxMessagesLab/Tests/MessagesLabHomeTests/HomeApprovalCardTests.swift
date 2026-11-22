import AppKit
import CmuxAgentQuestion
@testable import CmuxHomeCore
import CmuxHomeRender
import Foundation
import Testing
@testable import MessagesLabHome

/// The native Home transcript over its real store and mock conversation owner. The decider
/// stands in for acpmux; these tests prove card routing and recording, not a live daemon allow.
@MainActor @Suite(.serialized) struct HomeApprovalCardTests {
    @MainActor final class Decider: HomeApprovalDeciding {
        struct Call: Equatable { let request: HomeApprovalRequest; let allow: Bool }
        var calls: [Call] = []
        var result: HomeApprovalDecision
        var held = false
        private var waiting: CheckedContinuation<HomeApprovalDecision, Never>?

        init(_ result: HomeApprovalDecision = .answered) { self.result = result }

        func decide(_ request: HomeApprovalRequest, allow: Bool,
                    through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
            calls.append(Call(request: request, allow: allow))
            let answer: HomeApprovalDecision
            if held { answer = await withCheckedContinuation { waiting = $0 } }
            else { answer = result }
            if answer == .answered, !gate({}) { return .refused }
            return answer
        }

        func release(_ answer: HomeApprovalDecision) {
            let pending = waiting
            waiting = nil
            pending?.resume(returning: answer)
        }
    }

    static let requestJSON = #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf approval-test"}},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#

    func question() -> AgentQuestion {
        let permission = UUID().uuidString
        return AgentQuestion(id: "home-approval-\(permission)",
                             source: .init(harness: .chief, session: "local/test-subagent", permission: permission),
                             items: [.init(id: "approval:" + String(repeating: "a", count: 64), prompt: "a1 needs permission to run Bash",
                                           options: [.init(id: "allow", label: "Allow once", preview: .init(text: Self.requestJSON)),
                                                     .init(id: "deny", label: "Deny")], allowsOther: false)])
    }

    func request(_ question: AgentQuestion, chief: ParticipantID) -> HomeApprovalRequest {
        HomeApprovalRequest(chief: chief.rawValue, session: question.source.session,
                            permission: question.source.permission ?? "", requestJSON: Self.requestJSON)
    }

    func posted(_ question: AgentQuestion, in rig: HomeChatRig) async throws -> TranscriptItem {
        let key = IdempotencyKey("approval-test-\(UUID().uuidString)")
        #expect(await rig.post([.question(question)], key: key))
        rig.frame()
        return try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == key })
    }

    func currentQuestion(_ item: TranscriptItem, in rig: HomeChatRig) -> AgentQuestion? {
        guard let current = rig.store.transcript(for: HomeChatRig.conversation).first(where: { $0.key == item.key }),
              case .question(let question)? = current.parts.first else { return nil }
        return question
    }

    func payload(_ question: AgentQuestion, local: HomeApprovalRowProvider.Local = .init()) -> HomeApprovalRowProvider.Payload {
        .init(question: question, local: local)
    }

    func projectsApproval(_ item: TranscriptItem, summary: ConversationSummary?) -> Bool {
        HomeMapping.projectedParts(item, summary: summary).parts.contains { part in
            guard case .custom(let custom) = part else { return false }
            return HomeApprovalRowProvider.payload(custom) != nil
        }
    }

    @Test func onlyTheLocalChiefProjectsAnApprovalCard() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let question = question()
        let item = try await posted(question, in: rig)
        var local = try #require(rig.store.summary(HomeChatRig.conversation))
        local.owner = .local
        let parts = HomeMapping.projectedParts(item, summary: local).parts
        guard case .custom(let card)? = parts.first else { Issue.record("the local Chief approval did not render"); return }
        #expect(HomeApprovalRowProvider.payload(card)?.question == question)

        var forged = item
        forged.author = rig.me
        #expect(!projectsApproval(forged, summary: local))
        forged.author = ParticipantID("agent_not_in_roster")
        #expect(!projectsApproval(forged, summary: local))
        var cloud = local
        cloud.owner = .cloud
        #expect(!projectsApproval(item, summary: cloud))
        #expect(!projectsApproval(item, summary: nil))
    }

    @Test func aCardWithoutAFreshNativeGestureAnswersNothing() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider()
        rig.view.approvals = decider
        await rig.source.setOwner(.local, in: HomeChatRig.conversation)
        let question = question()
        let item = try await posted(question, in: rig)
        #expect(rig.view.projection.shownSummary?.owner == .local)
        let ref = MessagesLabHome.PartRef(messageId: HomeMapping.id(item, aliases: rig.view.projection.aliases), partIndex: 0)
        #expect(HomeApprovalGesture.capture(in: nil) == nil)
        #expect(rig.view.projection.decideApproval(ref, allow: true))
        #expect(decider.calls.isEmpty)
        #expect(currentQuestion(item, in: rig)?.isPending == true)
        #expect(rig.view.projection.approvalState(question.id).note == CmuxStrings.approvalFailed)
        #expect(!rig.view.projection.approvalState(question.id).ended)
    }

    @Test(arguments: [true, false])
    func theOwnerRecordsOnlyAfterTheNativeAnswerSucceeds(allow: Bool) async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider()
        decider.held = true
        rig.view.approvals = decider
        let question = question()
        let item = try await posted(question, in: rig)
        let message = try #require(item.messageID)
        let request = request(question, chief: rig.chief)
        let gate = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        let task = Task {
            await rig.view.projection.completeApproval(request, allow: allow, question: question,
                                                       message: message, partIndex: 0, through: { gate.write($0) })
        }
        await HomeChatRig.until { decider.calls.count == 1 }
        #expect(decider.calls == [.init(request: request, allow: allow)])
        #expect(currentQuestion(item, in: rig)?.isPending == true, "the conversation must not claim an unconfirmed answer")
        decider.release(.answered)
        let local = await task.value
        await HomeChatRig.until { currentQuestion(item, in: rig)?.isPending == false }
        guard case .answered(let answer)? = currentQuestion(item, in: rig)?.state else {
            Issue.record("the successful native answer was not recorded"); return
        }
        let itemID = try #require(question.items.first?.id)
        #expect(answer.selections[itemID]?.optionIDs == [allow ? "allow" : "deny"])
        #expect(answer.respondent?.participant == rig.me.rawValue)
        #expect(local.ended && !local.busy)
        #expect(local.note == (allow ? CmuxStrings.approvalAllowed : CmuxStrings.approvalDenied))
        #expect(!gate.write { Issue.record("one pointer gesture authorized a second answer") })
    }

    @Test func aRefusedAnswerStaysPendingAndCanBeRetried() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider(.refused)
        rig.view.approvals = decider
        let question = question()
        let item = try await posted(question, in: rig)
        let message = try #require(item.messageID)
        let request = request(question, chief: rig.chief)
        let gate = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        let local = await rig.view.projection.completeApproval(request, allow: true, question: question,
                                                              message: message, partIndex: 0, through: { gate.write($0) })
        #expect(currentQuestion(item, in: rig)?.isPending == true)
        #expect(local.note == CmuxStrings.approvalFailed)
        #expect(payload(question, local: local).takesClicks)
        decider.result = .answered
        let next = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        let retried = await rig.view.projection.completeApproval(request, allow: false, question: question,
                                                                message: message, partIndex: 0, through: { next.write($0) })
        #expect(retried.ended && retried.note == CmuxStrings.approvalDenied)
        #expect(decider.calls.map(\.allow) == [true, false])
    }

    @Test func anExpiredRequestDisablesTheCardWithoutRecordingAnAnswer() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider(.expired)
        rig.view.approvals = decider
        let question = question()
        let item = try await posted(question, in: rig)
        let local = await rig.view.projection.completeApproval(request(question, chief: rig.chief), allow: true, question: question,
                                                              message: try #require(item.messageID), partIndex: 0,
                                                              through: { _ in Issue.record("an expired request reached the write gate"); return false })
        #expect(currentQuestion(item, in: rig)?.isPending == true)
        #expect(local.ended && local.note == CmuxStrings.approvalExpired)
        let card = payload(question, local: local)
        #expect(!card.takesClicks)
        #expect(HomeApprovalRowProvider.layout(card, width: 420).allow.height == 0)
        #expect(HomeApprovalRowProvider.layout(card, width: 420).deny.height == 0)
    }

    @Test(arguments: [true, false])
    func anAnsweredRequestStaysDisabledWhenRecordingFails(allow: Bool) async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let decider = Decider()
        rig.view.approvals = decider
        let question = question()
        let item = try await posted(question, in: rig)
        let gate = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        let local = await rig.view.projection.completeApproval(request(question, chief: rig.chief), allow: allow, question: question,
                                                              message: MessageID("missing-after-native-answer"), partIndex: 0,
                                                              through: { gate.write($0) })
        #expect(decider.calls.count == 1)
        #expect(currentQuestion(item, in: rig)?.isPending == true)
        #expect(local.ended && !payload(question, local: local).takesClicks)
        #expect(local.note == (allow ? CmuxStrings.approvalAllowedNotRecorded : CmuxStrings.approvalDeniedNotRecorded))
        #expect(!gate.write { Issue.record("recording failure reused the completed native decision") })
    }

    @Test func oneGestureWritesOnceAndExpiredOrCancelledGesturesNeverWrite() {
        var writes = 0
        let once = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        #expect(once.write { writes += 1 })
        #expect(!once.write { writes += 1 })
        let expired = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime - 1)
        #expect(!expired.write { writes += 1 })
        let cancelled = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        cancelled.cancel()
        #expect(!cancelled.write { writes += 1 })
        #expect(writes == 1)
    }

    @Test func closingTheTranscriptCancelsPendingNativeWrites() async throws {
        let rig = try await HomeChatRig(history: 1)
        defer { rig.stop() }
        let gate = HomeApprovalWriteGate(deadline: ProcessInfo.processInfo.systemUptime + 60)
        rig.view.projection.approvalWrites.append(gate)
        rig.view.stop()
        #expect(rig.view.projection.approvalWrites.isEmpty)
        #expect(!gate.write { Issue.record("a closed transcript wrote an answer") })
    }

    @Test func theAppMustClassifyTheNativeEventAsThePersonsInput() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        try #require(NSApp.window(withWindowNumber: window.windowNumber) === window)
        // AppKit may quantize the supplied timestamp; keep this event safely in the past.
        let stamp = ProcessInfo.processInfo.systemUptime - 0.05
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: stamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        try #require(event.window === window)
        try #require((0..<5).contains(ProcessInfo.processInfo.systemUptime - event.timestamp))
        var classifierCalls = 0
        #expect(HomeApprovalGesture.capture(event, in: window, after: -1, isPerson: { _ in
            classifierCalls += 1
            return false
        }) == nil, "a posted pointer must not become a permission gesture")
        #expect(classifierCalls == 1, "the event reached the provenance classifier")
        let gate = try #require(HomeApprovalGesture.capture(event, in: window, after: -1, isPerson: { _ in true }))
        var writes = 0
        #expect(gate.write { writes += 1 })
        #expect(!gate.write { writes += 1 })
        #expect(writes == 1)
        #expect(HomeApprovalGesture.capture(event, in: window, after: event.timestamp, isPerson: { _ in true }) == nil,
                "this view already claimed the same pointer event")
    }

}
