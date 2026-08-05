import CmuxAgentChat
import CmuxAgentChatUI
import Foundation
import Testing

@testable import CmuxAgentGUIUI

@Suite("Agent transcript artifact routing")
struct AgentTranscriptArtifactRouteTests {
    @Test("presented artifacts retain the live transcript loader")
    func retainsLiveLoader() async throws {
        let expectedPath = "/tmp/agent-output.png"
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            scope: .chat(sessionID: "agent-session"),
            stat: { path in
                #expect(path == expectedPath)
                return ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: 128,
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    kind: .image,
                    mimeType: "image/png"
                )
            }
        )

        let route = AgentTranscriptArtifactRoute(path: expectedPath, loader: loader)

        #expect(route.path == expectedPath)
        #expect(route.loader.scope == .chat(sessionID: "agent-session"))
        #expect(try await route.loader.stat(path: route.path).exists)
    }
}
