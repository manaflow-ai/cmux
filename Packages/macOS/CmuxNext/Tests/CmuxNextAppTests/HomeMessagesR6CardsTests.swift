import CmuxAgentQuestion
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Round 6 F3 (cmux#37736): the Messages page's Chief permission card answers through the decider
/// the native card used, only on the person's click, and then records the answer on its message
/// (`HomeMessagesApprovals`, the port of MessagesLabHome `HomeProjection.decideApproval`).
@MainActor @Suite(.serialized)
struct HomeMessagesR6CardsTests {
    @MainActor final class Decider: HomeApprovalDeciding {
        var calls: [(HomeApprovalRequest, Bool)] = []
        var result: HomeApprovalDecision = .answered
        func decide(_ request: HomeApprovalRequest, allow: Bool,
                    through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
            calls.append((request, allow))
            if result == .answered, !gate({}) { return .refused }
            return result
        }
    }

    static let conversation = ConversationID("conv_chief")
    static let requestJSON = #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf approval-test"}}}"#

    static func question() -> AgentQuestion {
        AgentQuestion(id: "q-\(UUID().uuidString)", source: .init(harness: .chief, session: "local/test-subagent", permission: "perm-1"),
                      items: [.init(id: "approval:" + String(repeating: "a", count: 64), prompt: "a1 needs permission to run Bash",
                                    options: [.init(id: "allow", label: "Allow once", preview: .init(text: requestJSON)),
                                              .init(id: "deny", label: "Deny")], allowsOther: false)])
    }

    /// A started store on the mock owner, with one permission question posted by its Chief. The mock's
    /// conversations are Cloud ones (`ConversationSummary.owner` defaults to `.cloud`); only a local
    /// Chief's card is actionable (native `decideApproval`), so the Chief chat is made local first,
    /// as MessagesLabHome's `HomeApprovalCardTests` do.
    static func rig(owner: ConversationSummary.Owner = .local) async throws -> (MockHomeSource, HomeStore, Message) {
        let source = MockHomeSource(options: MockHomeSource.Options(chiefHistory: 1, latency: .zero, replyDelay: .seconds(3600)))
        let store = HomeStore(source: source)
        store.start()
        await source.setOwner(owner, in: conversation)
        for _ in 0..<20_000 where !(store.isOnline && store.summary(conversation)?.owner == owner) { await Task.yield() }
        #expect(store.summary(conversation)?.owner == owner)
        let chief = await source.chief.id
        let seq = try #require(await source.post([.question(question())], from: chief, in: conversation, key: IdempotencyKey("approval-\(UUID().uuidString)")))
        let message = try #require(try await source.history(of: conversation, before: seq + 1, limit: 1).first)
        return (source, store, message)
    }

    static func fields(_ message: Message, allow: Bool) -> [String: JSONValue] {
        ["conversation": .string(conversation.rawValue), "message": .string(message.id.rawValue),
         "seq": .number(Double(message.seq)), "partIndex": .number(0), "allow": .bool(allow)]
    }

    static func click(at event: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PageCallContext {
        PageCallContext(page: PageDescriptor.homeMessages.id, userGesture: true, gestureEvent: event)
    }

    @Test func aClickAnswersTheExactRequestAndRecordsTheAnswer() async throws {
        let (source, store, message) = try await Self.rig()
        defer { store.stop() }
        let decider = Decider()
        let approvals = HomeMessagesApprovals(store: store, decider: decider)
        let answer = try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true), context: Self.click())
        #expect(answer == .object(["note": .string("allowed"), "ended": .bool(true)]))
        #expect(decider.calls.count == 1)
        #expect(decider.calls.first?.0 == HomeApprovalRequest(chief: message.author.rawValue, session: "local/test-subagent",
                                                               permission: "perm-1", requestJSON: Self.requestJSON))
        #expect(decider.calls.first?.1 == true)
        let stored = try #require(try await source.history(of: Self.conversation, before: message.seq + 1, limit: 1).first)
        guard case .question(let recorded)? = stored.parts.first, case .answered(let chosen) = recorded.state else {
            Issue.record("the card's answer is recorded on its message")
            return
        }
        #expect(chosen.selections.values.first?.optionIDs == ["allow"])
        // Ended: a second click answers nothing.
        let again = try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: false), context: Self.click())
        #expect(again == .object(["note": .string("expired"), "ended": .bool(true)]))
        #expect(decider.calls.count == 1)
    }

    @Test func withoutTheClickNothingIsAnswered() async throws {
        let (_, store, message) = try await Self.rig()
        defer { store.stop() }
        let decider = Decider()
        let approvals = HomeMessagesApprovals(store: store, decider: decider)
        let failed = JSONValue.object(["note": .string("failed"), "ended": .bool(false)])
        // The page's own call (no gesture), a stale click, then one click spent twice.
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true),
                                         context: PageCallContext(page: PageDescriptor.homeMessages.id)) == failed)
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true),
                                         context: Self.click(at: ProcessInfo.processInfo.systemUptime - 6)) == failed)
        #expect(decider.calls.isEmpty, "no click: acpmux is never asked")
        decider.result = .refused
        let click = Self.click()
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true), context: click) == failed)
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true), context: click) == failed)
        #expect(decider.calls.count == 1, "one click answers at most once")
    }

    @Test func aCloudConversationsCardIsNeverAnswered() async throws {
        let (_, store, message) = try await Self.rig(owner: .cloud)
        defer { store.stop() }
        let decider = Decider()
        let approvals = HomeMessagesApprovals(store: store, decider: decider)
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: true), context: Self.click())
                == .object(["note": .string("failed"), "ended": .bool(false)]))
        #expect(decider.calls.isEmpty, "only a local Chief's card answers acpmux")
    }

    @Test func anExpiredRequestEndsTheCard() async throws {
        let (_, store, message) = try await Self.rig()
        defer { store.stop() }
        let decider = Decider()
        decider.result = .expired
        let approvals = HomeMessagesApprovals(store: store, decider: decider)
        #expect(try await approvals.call(HomeMessagesApprovals.op, Self.fields(message, allow: false), context: Self.click())
                == .object(["note": .string("expired"), "ended": .bool(true)]))
    }
}
