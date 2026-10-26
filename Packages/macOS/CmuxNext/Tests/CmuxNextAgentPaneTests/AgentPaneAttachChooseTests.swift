import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// The summary panel's Attach files or folders (`chat.attach.choose`): the open panel opens only
/// after a real gesture in the pane and only for a chat on this Mac, and answers what the user
/// picked as `{items: [{path, folder}]}`.
@MainActor
struct AgentPaneAttachChooseTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane whose open panel answers `picks`, counting how often it opened.
    private final class Rig {
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost())
        var picks: [URL] = []
        var opened = 0

        init() {
            model.onChooseAttachments = { [weak self] in
                guard let self else { return [] }
                opened += 1
                return picks
            }
        }

        func choose(gesture: Bool = true) async -> [String: Any] {
            if gesture { model.transport.gestures.record() }
            return await model.respond(to: AgentPaneRequest(body: ["method": "chat.attach.choose"]))
        }
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func decodesTheMethod() {
        #expect(AgentPaneRequest(body: ["method": "chat.attach.choose"]) == .chooseAttachments)
        #expect(AgentPageOps.methods["chat.attach.choose"] == "chat.attach.choose")
    }

    /// A file and a folder the user picked come back with whether each is a folder.
    @Test func answersThePickedFilesAndFolders() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("spec.md")
        try "# Spec".write(to: file, atomically: true, encoding: .utf8)

        let rig = Rig()
        rig.picks = [file, folder]
        let reply = await rig.choose()
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let items = try #require((reply["value"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["path"] as? String } == [file.path, folder.path])
        #expect(items.compactMap { $0["folder"] as? Bool } == [false, true])
    }

    /// A cancelled pick answers no items.
    @Test func cancelledAnswersNoItems() async {
        let rig = Rig()
        let reply = await rig.choose()
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["value"] as? [String: Any])?["items"] == nil)
        #expect(rig.opened == 1)
    }

    /// Page script without a real click never opens the panel.
    @Test func needsAGesture() async {
        let rig = Rig()
        rig.picks = [URL(fileURLWithPath: "/tmp/spec.md")]
        #expect(Self.errorCode(await rig.choose(gesture: false)) == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(rig.opened == 0)
    }

    /// A chat on another machine never gets this Mac's files.
    @Test func refusedForARemoteChat() async {
        let rig = Rig()
        rig.model.remoteChat = true
        rig.picks = [URL(fileURLWithPath: "/tmp/spec.md")]
        #expect(Self.errorCode(await rig.choose()) == "unsupported")
        #expect(rig.opened == 0)
    }
}
