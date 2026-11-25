@testable import CmuxNextAgentPane
import Testing

/// #35415 item 1: the handshake reads the store's start folder while acpmux connects
/// (``AgentPaneStartFolders/prefetch(for:)``). A prefetch that got no answer (a transient
/// `workspace.agent_start.get` failure, a cold start before the daemon connected) is asked again,
/// so the handshake still names the store's folder instead of falling back to the old rules.
@MainActor @Suite
struct AgentPaneStartPrefetchRetryTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    final class Store {
        var asked = 0
    }

    @Test func anEmptyPrefetchIsAskedAgain() async throws {
        let model = AgentPaneModel(host: Host(), newTab: AgentPaneNewTab(kind: .agent))
        let store = Store()
        model.startFolders.resolve = { _ in
            store.asked += 1
            // The first ask (the prefetch) finds no daemon yet; the next one answers.
            return store.asked == 1 ? nil : AgentPaneStartFolder(kind: .workspace, cwd: "/work/project", agentHome: nil)
        }
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(store.asked == 2)
        #expect(value["startKind"] as? String == "workspace")
        #expect(value["cwd"] as? String == "/work/project")
    }

    /// A prefetch that answered is the handshake's answer: no second read.
    @Test func anAnsweredPrefetchIsNotAskedAgain() async throws {
        let model = AgentPaneModel(host: Host(), newTab: AgentPaneNewTab(kind: .agent))
        let store = Store()
        model.startFolders.resolve = { _ in
            store.asked += 1
            return AgentPaneStartFolder(kind: .workspace, cwd: "/work/project", agentHome: nil)
        }
        _ = await model.respond(to: .ready)
        #expect(store.asked == 1)
    }
}
