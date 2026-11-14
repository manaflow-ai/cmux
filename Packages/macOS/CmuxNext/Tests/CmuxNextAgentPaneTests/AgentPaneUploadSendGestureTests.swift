import Foundation
import Testing
@testable import CmuxNextAgentPane

/// One Enter or click pays for both the send and the uploads still pending in the composer
/// (Leo, 2026-11-06: "why is this still happening"). The composer binds a held send's Enter to its
/// prompt at once (`transport.gesture`); a file pasted just before begins its upload only after the
/// host answered where the paste's files are. Both took the gesture's one grant, so whichever came
/// second was refused: the send ("Not sent: it needs your own key press or click.") or, once the
/// send bound first, the upload, and a PDF or a video (no preview to fall back on) kept the send
/// waiting for good. A gesture now gives an upload credit of its own beside the grant.
@MainActor
struct AgentPaneUploadSendGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane() -> (AgentPaneModel, () -> Int) {
        let model = AgentPaneModel(host: NoHost())
        var begun = 0
        model.onUploadStage = {
            { _, _ in
                begun += 1
                return AgentPaneReply.success(["token": "t-\(begun)", "size": 3, "chunkSize": 512 * 1024])
            }
        }
        return (model, { begun })
    }

    /// The Enter: the gesture is recorded, and the held send binds it to its prompt first.
    private func enterBindsSend(_ model: AgentPaneModel) throws {
        model.transport.gestures.record()
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "held-1"]]]))
        #expect(model.transport.gestures.reserve(connection: 0, intent: send) != nil)
    }

    private func begins(_ model: AgentPaneModel, _ name: String, batch: [AgentPaneUploadBatchEntry]? = nil) async -> Bool {
        let reply = await model.respond(to: .uploadStage(.begin(name: name, size: 3, batchToken: nil, batch: batch)))
        return reply["ok"] as? Bool == true
    }

    @Test func aPdfPastedBeforeEnterUploadsAfterTheSendBoundTheEnter() async throws {
        let (model, begun) = pane()
        try enterBindsSend(model)
        #expect(await begins(model, "spec.pdf"))
        #expect(begun() == 1)
    }

    @Test func aVideoPastedBeforeEnterUploadsAfterTheSendBoundTheEnter() async throws {
        let (model, begun) = pane()
        try enterBindsSend(model)
        #expect(await begins(model, "demo.mp4"))
        #expect(begun() == 1)
    }

    @Test func aMixedImageAndPdfBatchUploadsAfterTheSendBoundTheEnter() async throws {
        let (model, begun) = pane()
        try enterBindsSend(model)
        let batch = [AgentPaneUploadBatchEntry(name: "shot.png", size: 3), AgentPaneUploadBatchEntry(name: "spec.pdf", size: 3)]
        #expect(await begins(model, "shot.png", batch: batch))
        #expect(begun() == 1)
    }

    /// The upload credit is the gesture's: one batch per key press or click, and none without one.
    @Test func noGestureNoUploadAndOneBatchPerGesture() async throws {
        let (model, begun) = pane()
        #expect(!(await begins(model, "script.pdf")))
        try enterBindsSend(model)
        #expect(await begins(model, "first.pdf"))
        #expect(!(await begins(model, "second.pdf")))
        #expect(begun() == 1)
    }

    /// The upload spends only its own credit: the send's grant is still there after it.
    @Test func anUploadLeavesTheGrantForTheSend() async throws {
        let (model, _) = pane()
        model.transport.gestures.record()
        #expect(await begins(model, "spec.pdf"))
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        #expect(model.transport.gestures.reserve(connection: 0, intent: send) != nil)
    }
}
