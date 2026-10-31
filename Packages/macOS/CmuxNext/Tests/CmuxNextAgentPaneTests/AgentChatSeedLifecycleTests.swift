@testable import CmuxNextAgentPane
import Testing

@MainActor @Suite
struct AgentChatSeedLifecycleTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    @Test func explicitPeerAndModelSurvivePeekTakeAndReadyWithoutLocalFolderResolution() async throws {
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "/remote/project", harness: "fake", model: "fixture-model", host: "dev-box"))
        #expect(!seed.holdsOnlyFolder)
        #expect(await seed.peek()?.host == "dev-box")
        #expect(await seed.take()?.model == "fixture-model")
        #expect(!seed.holdsOnlyFolder)
        let model = AgentPaneModel(host: Host(), seed: seed)
        var localFolderReads = 0
        model.startFolders.resolve = { _ in localFolderReads += 1; return nil }
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["cwd"] as? String == "/remote/project")
        #expect(value["harness"] as? String == "fake")
        #expect(value["model"] as? String == "fixture-model")
        #expect(value["peer"] as? String == "dev-box")
        #expect(model.handshakeCwd == "/remote/project")
        #expect(model.remoteChat)
        #expect(localFolderReads == 0)
    }

    @Test func noArgumentSeedStillAllowsFolderOnlyReplacement() async {
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp"))
        #expect(seed.holdsOnlyFolder)
        #expect(await seed.take()?.model == nil)
        #expect(await seed.peek()?.host == nil)
        #expect(seed.holdsOnlyFolder)
    }
}
