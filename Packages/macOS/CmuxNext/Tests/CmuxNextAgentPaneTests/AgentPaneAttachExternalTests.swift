import AppKit
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

    /// Send to cmux Chat takes the image files Finder selected, and keeps a picture's bytes under
    /// Chat Uploads as a file the route can hand on.
    @Test func theServiceTakesImageFilesAndKeepsAPicture() async throws {
        #expect(AgentPaneDroppedPaths.imageFiles(["/tmp/a.png", "/tmp/b.txt", "/tmp/c.HEIC", "/tmp/docs"]).map(\.path)
            == ["/tmp/a.png", "/tmp/c.HEIC"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let written = await AgentPaneDroppedPaths.save(Data([3]), ext: "png", in: ChatUploadFolders(root: root))
        let saved = try #require(written)
        #expect(saved.lastPathComponent == "Image.png")
        #expect(saved.path.hasPrefix(root.path))
        #expect(try Data(contentsOf: saved) == Data([3]))
    }

    /// A push that waits for the page's client runs once, when the page says its client is ready, and
    /// not when it says it is not.
    @Test func aPushForAPageStillLoadingWaitsForItsClient() async {
        let model = Self.model()
        var ran = 0
        model.whenClientReady = { ran += 1 }
        _ = await Self.ask(model, "pane.clientReady", ["ready": false])
        #expect(ran == 0)
        _ = await Self.ask(model, "pane.clientReady", ["ready": true])
        _ = await Self.ask(model, "pane.clientReady", ["ready": true])
        #expect(ran == 1 && model.whenClientReady == nil)
    }

    /// Whether this process reaches a pasteboard server: a fleet test step often does not, and there
    /// every write fails and every read returns nil (as `AttachmentSourceTests` finds).
    nonisolated private static let hasPasteboard: Bool = {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-external-probe-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        return board.setString("probe", forType: .string) && board.string(forType: .string) == "probe"
    }()

    /// Without image files the Service takes a picture's bytes, PNG first, else TIFF.
    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server")) func theServiceReadsAPicturePNGFirst() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("external-image-data-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(AgentPaneDroppedPaths.imageData(on: pasteboard) == nil)
        pasteboard.setData(Data([1, 2]), forType: .tiff)
        #expect(AgentPaneDroppedPaths.imageData(on: pasteboard)?.ext == "tiff")
        pasteboard.setData(Data([3]), forType: .png)
        let picture = try #require(AgentPaneDroppedPaths.imageData(on: pasteboard))
        #expect(picture.data == Data([3]) && picture.ext == "png")
    }

    /// Files that come while a new chat opens for earlier ones join them: one new chat, not two;
    /// a chat that could not start leaves nothing waiting.
    @Test func filesWhileANewChatOpensJoinIt() {
        let route = AgentPaneExternalAttach()
        var opened = 0
        let open: (@escaping @MainActor (AgentPaneView?) -> Void) -> Bool = { _ in
            opened += 1
            return true
        }
        route.attach([URL(fileURLWithPath: "/tmp/a.png")], claimed: nil, target: nil, openChat: open, show: { _ in })
        route.attach([URL(fileURLWithPath: "/tmp/b.png")], claimed: nil, target: nil, openChat: open, show: { _ in })
        #expect(opened == 1)
        #expect(route.waitsForChat)
        let refused = AgentPaneExternalAttach()
        refused.attach([URL(fileURLWithPath: "/tmp/a.png")], claimed: nil, target: nil, openChat: { _ in false }, show: { _ in })
        #expect(!refused.waitsForChat)
    }
}
