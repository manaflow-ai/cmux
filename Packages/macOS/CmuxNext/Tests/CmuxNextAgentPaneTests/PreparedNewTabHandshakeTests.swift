@testable import CmuxNextAgentPane
import Testing

/// SHORTCUT FRAMES F2 review: the spare pool gives a parked New Tab spare the context a Cmd-T would make
/// (NewTabSparePool.prepare), so its first frame after the key is final. That context's folder is no tab's yet: the
/// spare's handshake, a reconnect's too, must not take it as the chat's folder (handshakeCwd: its path roots, the
/// terminal folder, the start folder of a new session), or the tab the spare goes to keeps another tab's folder.
@MainActor @Suite
struct PreparedNewTabHandshakeTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    @Test(arguments: [AgentPaneRequest.ready, .reconnect])
    func aPreparedContextsFolderIsNotTheHandshakes(_ request: AgentPaneRequest) async throws {
        let model = AgentPaneModel(host: Host(), newTab: AgentPaneNewTab(kind: .agent))
        model.startFolders.resolve = { _ in nil }
        model.adoptNewTab(AgentPaneNewTab(kind: .agent, cwd: "/other/tabs/project"))
        model.newTabPrepared = true
        let reply = await model.respond(to: request)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["cwd"] as? String != "/other/tabs/project")
        #expect(model.handshakeCwd != "/other/tabs/project")
        #expect(!model.roots().contains("/other/tabs/project"), "a prepared folder is no root of the parked page")
    }

    /// A tab's own context (Cmd-T adopted the page) still names the chat's folder.
    @Test func anAdoptedTabsFolderIsTheHandshakes() async throws {
        let model = AgentPaneModel(host: Host(), newTab: AgentPaneNewTab(kind: .agent))
        model.startFolders.resolve = { _ in nil }
        model.adoptNewTab(AgentPaneNewTab(kind: .agent, cwd: "/tabs/project"))
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["cwd"] as? String == "/tabs/project")
    }
}
