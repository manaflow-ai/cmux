import CmuxMobileAgentChat
import CmuxAgentQuestion
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileLive

/// Review m10: a permission card says "Allowed" only once the signed Allow
/// went out; until then it says it waits for Face ID and offers no buttons.
@MainActor
@Suite struct FeedPendingTests {
    @MainActor final class HeldActions: FeedActions {
        var release: CheckedContinuation<Void, any Error>?
        var responds = 0
        func refresh() async throws {}
        func answer(_ item: FeedItem, question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {}
        func decline(_ item: FeedItem, question: AgentQuestion) async throws {}
        func respond(_ item: FeedItem, request: ACPPermissionRequest, option: ACPPermissionOption) async throws {
            responds += 1
            try await withCheckedThrowingContinuation { release = $0 }
        }
        func message(for error: any Error) -> String { "Not approved: Face ID was cancelled." }
    }

    static func store() throws -> (FeedStore, ACPPermissionOption, ACPPermissionOption) {
        let call = try JSONDecoder().decode(ACPToolCall.self, from: Data(#"{"toolCallId":"c","title":"rm","kind":"execute"}"#.utf8))
        let allow = ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce)
        let deny = ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce)
        let item = FeedItem(id: "p1", kind: .permission(ACPPermissionRequest(id: "perm", toolCall: call, options: [allow, deny])),
                            workspaceID: "w", tabID: "t", agentName: "Claude", harness: "claude", workspaceTitle: "w",
                            markdown: "", quote: nil, createdAt: Date())
        return (FeedStore(items: [item]), allow, deny)
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { await Task.yield() }
    }

    @Test func allowedOnlyAfterTheSignedAllowWentOut() async throws {
        let (store, allow, deny) = try Self.store()
        let actions = HeldActions()
        store.actions = actions
        store.respond("p1", option: allow)
        #expect(store.item(id: "p1")?.resolution == nil)
        #expect(store.item(id: "p1")?.pending == FeedStore.waitingForFaceID)
        await settle { actions.release != nil }
        // A Deny while Face ID is up sends nothing more.
        store.respond("p1", option: deny)
        #expect(actions.responds == 1)
        actions.release?.resume()
        await settle { store.item(id: "p1")?.resolution != nil }
        #expect(store.item(id: "p1")?.resolution == "Allowed once")
        #expect(store.item(id: "p1")?.pending == nil)
    }

    @Test func aCancelledFaceIDPutsTheCardBack() async throws {
        let (store, allow, _) = try Self.store()
        let actions = HeldActions()
        store.actions = actions
        store.respond("p1", option: allow)
        await settle { actions.release != nil }
        actions.release?.resume(throwing: AcpmuxHub.ApprovalCancelled())
        await settle { store.item(id: "p1")?.pending == nil }
        #expect(store.item(id: "p1")?.resolution == nil)
        #expect(store.item(id: "p1")?.error == "Not approved: Face ID was cancelled.")
    }
}
