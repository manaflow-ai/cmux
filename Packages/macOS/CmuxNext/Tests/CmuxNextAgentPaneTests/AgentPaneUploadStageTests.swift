import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A paste in a chat with no session yet (a new chat before its first prompt) stages its file like
/// any other: the App's stager takes a nil session (``AgentChatUploads`` saves under its root),
/// so the composer never falls back to one `chat.upload` frame, which the Chromium page host drops
/// past 4 MiB.
@MainActor
struct AgentPaneUploadStageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aChatWithNoSessionYetStagesItsUpload() async {
        let model = AgentPaneModel(host: NoHost())
        var asked: [String?] = []
        model.onUploadStage = {
            { _, session in
                asked.append(session)
                return AgentPaneReply.success(["token": "t", "size": 3, "chunkSize": 512 * 1024])
            }
        }
        model.transport.gestures.record()
        let reply = await model.respond(to: .uploadStage(.begin(name: "shot.png", size: 3, batchToken: nil, batch: nil)))
        #expect(reply["ok"] as? Bool == true)
        #expect(asked == [nil])
    }

    @Test func aPaneWithNoStagerStillAnswersUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.gestures.record()
        let reply = await model.respond(to: .uploadStage(.begin(name: "shot.png", size: 3, batchToken: nil, batch: nil)))
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }
}
