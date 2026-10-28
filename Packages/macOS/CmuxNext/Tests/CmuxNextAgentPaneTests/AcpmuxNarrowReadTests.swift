@testable import CmuxNextAgentPane
import Foundation
import Testing

@Suite struct AcpmuxNarrowReadTests {
    @Test func aSessionInfoRowBuildsTheDeepLinkSubject() {
        let found = AcpmuxSessionPage.chat("closed-1", in: [
            "sessionId": "closed-1", "name": "huge-blue/fix", "title": "Fix", "harness": "codex", "peer": "huge-blue",
        ])
        #expect(found?.chat == AcpmuxSessionPage.Chat(id: "closed-1", title: "Fix", harness: "codex"))
        #expect(found?.peer == "huge-blue")
    }

    @Test func sessionInfoFolderUsesTheSingleRowAndPeerBoundary() {
        let remote = AgentPaneSessionFolder(sessionId: "s1", info: [
            "sessionId": "s1", "cwd": "/work", "peer": "gcp-codex-lane-1",
        ])
        #expect(remote == AgentPaneSessionFolder(cwd: "/work", isLocal: false))
        let local = AgentPaneSessionFolder(sessionId: "s2", info: ["sessionId": "s2", "cwd": "/work"])
        #expect(local?.isLocal == true)
    }
}
