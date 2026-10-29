import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-cuk4 at the relay boundary (the page's frames into ``AgentPaneTransport``): Enable on a folder
/// harness asks acpmux for its prompt first. When acpmux refuses (no Trust answer, an invalid file),
/// the page's request is answered with acpmux's reason, so the page can show why, not only the
/// code a Cancel on the sheet also answers.
@Suite(.serialized)
@MainActor
struct AgentPaneHarnessEnableRelayTests {
    @Test func anEnableAcpmuxRefusesAnswersThePageWithAcpmuxsReason() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cuk4-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [folder] }
        transport.harnessEnablePrompt = { _, _ in
            throw AcpmuxRPCError(message: "harness 'mine': \(folder) has no Trust answer")
        }
        var sheets = 0
        transport.requestHarnessEnable = { _, answer in sheets += 1; answer(true) }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)

        transport.gestures.record()
        let enable = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/harness_enable","params":{"folder":"\#(folder)","id":"mine"}}"#
        #expect(await transport.send(connection: id, frames: [enable]) == .harnessNotConfirmed)
        let reply = await inbox.frame(containing: #""id":7"#)
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        let data = try #require((object?["error"] as? [String: Any])?["data"] as? [String: Any])
        #expect(data["code"] as? String == "transport.harness_not_confirmed")
        #expect(data["detail"] as? String == "harness 'mine': \(folder) has no Trust answer")
        #expect(sheets == 0, "no sheet without a prompt")
        #expect(server.peers.first?.frames.contains { $0.contains("harness_enable") } != true,
                "nothing reached acpmux")
    }

    /// cx-nt39g: acpmux down or too slow to give the prompt answers the page with a reason it can
    /// show (`harness.prompt_unavailable`), not the bare code a Cancel gives.
    @Test func anEnableWithoutAPromptFromAcpmuxSaysSo() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("nt39g-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [folder] }
        transport.harnessEnablePrompt = { _, _ in throw AcpmuxStatusClient.Failure.unreachable("no daemon") }
        transport.requestHarnessEnable = { _, answer in answer(true) }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)

        transport.gestures.record()
        let enable = #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/harness_enable","params":{"folder":"\#(folder)","id":"mine"}}"#
        #expect(await transport.send(connection: id, frames: [enable]) == .harnessNotConfirmed)
        let reply = await inbox.frame(containing: #""id":8"#)
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        let data = try #require((object?["error"] as? [String: Any])?["data"] as? [String: Any])
        #expect(data["code"] as? String == "transport.harness_not_confirmed")
        #expect(data["reason"] as? String == "harness.prompt_unavailable")
    }

    /// A sheet dropped without an answer (the pane closed while it was up) is a
    /// refusal, not a send line that waits for ever. A raw continuation leaked the wait here.
    @Test(.timeLimit(.minutes(1)))
    func anEnableWhoseSheetIsDroppedUnansweredIsNotConfirmed() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("p10-085-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [folder] }
        transport.harnessEnablePrompt = { asked, id in
            AgentPaneHarnessEnablePrompt(id: id, folder: asked, path: asked + "/.acpmux/harness.toml", argv: ["mine"],
                                         program: nil, env: [], checkedFiles: [], warnings: [], sha256: "abc")
        }
        var sheets = 0
        transport.requestHarnessEnable = { _, _ in sheets += 1 }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)

        transport.gestures.record()
        let enable = #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/harness_enable","params":{"folder":"\#(folder)","id":"mine"}}"#
        #expect(await transport.send(connection: id, frames: [enable]) == .harnessNotConfirmed)
        let reply = await inbox.frame(containing: #""id":9"#)
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        let data = try #require((object?["error"] as? [String: Any])?["data"] as? [String: Any])
        #expect(data["code"] as? String == "transport.harness_not_confirmed")
        #expect(sheets == 1, "the sheet was asked for once")
        #expect(server.peers.first?.frames.contains { $0.contains("harness_enable") } != true,
                "nothing reached acpmux")
    }
}
