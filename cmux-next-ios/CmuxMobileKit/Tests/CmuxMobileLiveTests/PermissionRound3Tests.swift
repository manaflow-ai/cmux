import CmuxMobileAgentChat
import CmuxAgentQuestion
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileLive

/// Parity round 3: a phone offers only what acpmux accepts from it (allow once, deny), in the
/// Mac pane's words, and an ask answered on the Mac first closes instead of reopening.
@MainActor
@Suite struct PermissionRound3Tests {
    static let call = try! JSONDecoder().decode(ACPToolCall.self, from: Data(#"{"toolCallId":"c","title":"rm","kind":"execute"}"#.utf8))

    @Test func phoneOffersOnlySingleUseOptions() {
        let options = [ACPPermissionOption(id: "allow_once", name: "Allow", kind: .allowOnce),
                       ACPPermissionOption(id: "allow_always", name: "Allow for this session", kind: .allowAlways),
                       ACPPermissionOption(id: "reject_once", name: "Reject", kind: .rejectOnce)]
        let request = ACPPermissionRequest(id: "p", toolCall: Self.call, options: options)
        #expect(request.phoneOptions.map(\.id) == ["allow_once", "reject_once"])
        #expect(request.phoneOptions.map(\.phoneLabel) == ["Allow once", "Deny"])
        // An option with its own words keeps them (AskUserQuestion's "Answer").
        #expect(ACPPermissionOption(id: "a", name: "Answer", kind: .allowOnce).phoneLabel == "Answer")
        // Nothing single-use: keep what was offered, so acpmux's refusal says why.
        let lasting = ACPPermissionRequest(id: "q", toolCall: Self.call, options: [options[1]])
        #expect(lasting.phoneOptions.map(\.id) == ["allow_always"])
        // A lasting Allow with a single-use Deny: not a lone Deny (review, round 3).
        let mixed = ACPPermissionRequest(id: "r", toolCall: Self.call, options: [options[1], options[2]])
        #expect(mixed.phoneOptions.map(\.id) == ["allow_always", "reject_once"])
    }

    @MainActor final class GoneActions: FeedActions {
        let live = LiveFeed(store: FeedStore(items: []), hub: nil, place: { _ in nil })
        func refresh() async throws {}
        func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {}
        func decline(_ item: FeedItem, question: AgentQuestion) async throws {}
        func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws {
            throw AcpmuxConnection.RPCError(code: -32004, message: "no pending permission perm", reason: nil)
        }
        func message(for error: any Error) -> String { live.message(for: error) }
        func isAlreadyAnswered(_ error: any Error) -> Bool { live.isAlreadyAnswered(error) }
    }

    @Test func anAskAnsweredOnTheMacCloses() async throws {
        let allow = ACPPermissionOption(id: "allow", name: "Allow", kind: .allowOnce)
        let item = FeedItem(id: "p1", kind: .permission(ACPPermissionRequest(id: "perm", toolCall: Self.call, options: [allow])),
                            workspaceID: "w", tabID: "t", agentName: "Claude", harness: "claude", workspaceTitle: "w",
                            markdown: "", quote: nil, createdAt: Date())
        let store = FeedStore(items: [item])
        let actions = GoneActions()
        store.actions = actions
        store.respond("p1", option: allow)
        for _ in 0..<500 where store.item(id: "p1")?.pending != nil { await Task.yield() }
        #expect(store.item(id: "p1")?.resolution == FeedStore.answeredElsewhere)
        #expect(store.item(id: "p1")?.error == nil)
        #expect(AcpmuxSessionSource.message(AcpmuxConnection.RPCError(code: -32004, message: "no pending permission x", reason: nil))
            == "Already answered on your Mac.")
        #expect(AcpmuxSessionSource.message(AcpmuxConnection.RPCError(code: -32000, message: "refused", reason: "remote.lasting_grant_refused"))
            == "From an iPhone you can allow once or deny. Allow for this chat on the Mac.")
    }
}
