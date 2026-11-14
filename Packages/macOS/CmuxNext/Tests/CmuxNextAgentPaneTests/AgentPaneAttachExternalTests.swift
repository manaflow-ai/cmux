import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Files another app sends to a chat (the Send to cmux Chat service, an image opened with cmux): the
/// App holds them on the pane (``AgentPaneDroppedPaths/hold(external:claimed:)``), the page takes them
/// once (`chat.attach.external`) and adds them as a drop's, so its `chat.attach.dropped` and
/// `chat.attach.source` asks of kind `external` answer for them. `chat.composer.get` reads the
/// composer back in one shape (``AgentPaneModel/composerJSON(session:page:kept:)``).
@MainActor
struct AgentPaneAttachExternalTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func model() -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.onLocalPaths = { true }
        return model
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any] = [:]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func files(_ reply: [String: Any]) -> [[String: Any]]? {
        (reply["value"] as? [String: Any])?["files"] as? [[String: Any]]
    }

    /// A PNG's first bytes in `Screenshot.png`, and a folder, in a fresh temporary folder.
    private static func sent() throws -> (image: URL, folder: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("Screenshot.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: image)
        return (image, folder)
    }

    @Test func decodesTheMethodAndKind() {
        #expect(AgentPaneRequest(body: ["method": "chat.attach.external"]) == .attachExternal)
        #expect(AgentPageOps.methods["chat.attach.external"] == "chat.attach.external")
        #expect(String(describing: AgentPaneRequest.attachExternal) == "attachExternal")
        #expect(AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "external", "names": ["a.png"]]])
            == .attachDropped(.external, names: ["a.png"]))
    }

    @Test func thePageTakesTheHeldFilesOnceAsAnExternalGesture() async throws {
        let (image, folder) = try Self.sent()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        let model = Self.model()
        #expect(Self.files(await Self.ask(model, "chat.attach.external"))?.isEmpty == true)
        model.droppedPaths.hold(external: [image, folder], claimed: "com.apple.Preview")
        #expect(!model.transport.gestures.isAvailable)

        let files = try #require(Self.files(await Self.ask(model, "chat.attach.external")))
        // A folder is no file the page can add.
        #expect(files.count == 1)
        #expect(files.first?["name"] as? String == "Screenshot.png")
        #expect(files.first?["type"] as? String == "image/png")
        let bytes = try Data(contentsOf: image)
        #expect((files.first?["data"] as? String).flatMap { Data(base64Encoded: $0) } == bytes)
        // Taken once.
        #expect(Self.files(await Self.ask(model, "chat.attach.external"))?.isEmpty == true)

        // The page's asks for them answer as for a drop: where it is, and the app it came from.
        let dropped = await Self.ask(model, "chat.attach.dropped", ["kind": "external", "names": ["Screenshot.png"]])
        let items = try #require((dropped["value"] as? [String: Any])?["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["path"] as? String } == [image.path])
        #expect(model.droppedPaths.source(.external, names: ["Screenshot.png"])?.claimed == "com.apple.Preview")
        // Its upload credit only: no grant for page script to spend.
        #expect(model.transport.gestures.consumeUpload())
        #expect(!model.transport.gestures.consume())
    }

    @Test func filesSentBeforeThePageTakesThemGoTogether() throws {
        let paths = AgentPaneDroppedPaths()
        let first = URL(fileURLWithPath: "/tmp/a.png"), second = URL(fileURLWithPath: "/tmp/b.png")
        paths.hold(external: [first], claimed: nil)
        paths.hold(external: [second], claimed: "com.apple.Preview")
        let held = try #require(paths.takeExternal())
        #expect(held.urls == [first, second])
        #expect(held.claimed == "com.apple.Preview")
        #expect(paths.takeExternal() == nil)
        // Another chat in the pane never gets them.
        paths.hold(external: [first], claimed: nil)
        paths.clearForSessionChange()
        #expect(paths.takeExternal() == nil)
    }

    @Test func theReadbackIsOneShapeFromThePageOrTheKeptChips() {
        let page: JSONValue = .object([
            "text": .string("what is this"),
            "attachments": .array([.object(["name": .string("Screenshot.png"), "mimeType": .string("image/png"),
                                            "bytes": .number(1234), "source": .string("Screenshot")])]),
        ])
        #expect(AgentPaneModel.composerJSON(session: "s1", page: page, kept: []) == .object([
            "session": .string("s1"),
            "attachments": .array([.object(["name": .string("Screenshot.png"), "mimeType": .string("image/png"),
                                            "bytes": .number(1234), "source": .string("Screenshot")])]),
            "text": .string("what is this"),
        ]))
        let kept = [AgentPaneWakeState.Attachment(id: "1", kind: "image", name: "a.png", mimeType: "image/png", size: 10,
                                                  source: AttachmentSource(name: "Preview"))]
        #expect(AgentPaneModel.composerJSON(session: nil, page: nil, kept: kept) == .object([
            "session": .null,
            "attachments": .array([.object(["name": .string("a.png"), "mimeType": .string("image/png"),
                                            "bytes": .number(10), "source": .string("Preview")])]),
            "text": .string(""),
        ]))
    }
}
