import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The user, 2026-11-01: "i wanna be able to select all in composer which also selects all the
/// attachments as the copy as well". The composer's Copy or Cut of a selection with attachments
/// sends `composer.copy {text, items}`; the host puts the text, then each attachment as a file, on
/// the pasteboard, as Claude desktop does. The items are recorded, never written: the CI Macs'
/// pasteboard server answers inconsistently (HomePasteAnywhereTests), and the user's clipboard is
/// never touched.
@MainActor @Suite(.serialized)
struct AgentPaneComposerCopyTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A real 2×2 PNG.
    private static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }()

    private final class Effects {
        var copied: [[NSPasteboardItem]] = []
    }

    private static func ask(_ model: AgentPaneModel, _ params: [String: Any], click: Bool = true) async -> [String: Any] {
        if click { model.transport.gestures.record() }
        return await model.respond(to: AgentPaneRequest(body: ["method": "composer.copy", "params": params]))
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("composer-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func model(_ folder: URL) -> (AgentPaneModel, Effects) {
        let model = AgentPaneModel(host: NoHost())
        let effects = Effects()
        model.replyLinks.imageFolder = folder.appendingPathComponent("copies", isDirectory: true)
        model.replyLinks.copyItems = { effects.copied.append($0); return true }
        model.replyLinks.copyItem = { _ in Issue.record("composer.copy wrote a single item"); return false }
        return (model, effects)
    }

    private static func fileURL(_ item: NSPasteboardItem) -> URL? {
        item.string(forType: .fileURL).flatMap(URL.init(string:))
    }

    // MARK: The contract

    @Test func theRequestTakesTextAndOneToSixtyFourItemsOfOnePayloadEach() throws {
        let png = ["name": "chart.png", "mimeType": "image/png", "data": Self.png.base64EncodedString()]
        let request = try #require(AgentPaneReplyRequest(method: "composer.copy", params: [
            "text": "see these",
            "items": [png, ["name": "notes.md", "mimeType": "text/markdown", "text": "# hi"],
                      ["name": "a", "mimeType": "", "path": "/tmp/a"]],
        ]))
        guard case .copyComposer(let text, let items) = request else { Issue.record("\(request)"); return }
        #expect(text == "see these")
        #expect(items.map(\.name) == ["chart.png", "notes.md", "a"])
        #expect(items[1].payload == .text("# hi"))
        #expect(items[2].payload == .path("/tmp/a"))
        #expect(!request.isPassive)
        // The text may be empty: a selection of attachments only.
        #expect(AgentPaneReplyRequest(method: "composer.copy", params: ["text": "", "items": [png]]) != nil)

        let refused: [[String: Any]] = [
            [:],
            ["text": "x"],
            ["items": [png]],
            ["text": "x", "items": []],
            ["text": "x", "items": Array(repeating: png, count: 65)],
            ["text": "x", "items": [png], "extra": 1],
            ["text": 1, "items": [png]],
            ["text": "a\u{0}b", "items": [png]],
            ["text": "x", "items": ["not an object"]],
            // An unknown key, no payload, two payloads, a missing name or type.
            ["text": "x", "items": [["name": "a", "mimeType": "text/plain", "text": "a", "url": "https://a.example"]]],
            ["text": "x", "items": [["name": "a", "mimeType": "text/plain"]]],
            ["text": "x", "items": [["name": "a", "mimeType": "text/plain", "text": "a", "path": "/tmp/a"]]],
            ["text": "x", "items": [["mimeType": "text/plain", "text": "a"]]],
            ["text": "x", "items": [["name": "a", "text": "a"]]],
            // A relative path, empty data, a NUL in a name, a name over 255 bytes.
            ["text": "x", "items": [["name": "a", "mimeType": "", "path": "tmp/a"]]],
            ["text": "x", "items": [["name": "a", "mimeType": "image/png", "data": ""]]],
            ["text": "x", "items": [["name": "a\u{0}", "mimeType": "text/plain", "text": "a"]]],
            ["text": "x", "items": [["name": String(repeating: "n", count: 256), "mimeType": "text/plain", "text": "a"]]],
        ]
        for params in refused {
            #expect(AgentPaneReplyRequest(method: "composer.copy", params: params) == nil, "\(params)")
        }
    }

    @Test func thePageReachesTheOpThroughTheAgentNamespace() {
        #expect(AgentPaneReplyRequest.methods.contains("composer.copy"))
        #expect(AgentPageOps.method(for: "cmux.agent.composer.copy") == "composer.copy")
    }

    // MARK: The copy

    @Test func textThenEachAttachmentAsAFileInOrder() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)

        let reply = await Self.ask(model, [
            "text": "look at these",
            "items": [
                ["name": "chart.png", "mimeType": "image/png", "data": Self.png.base64EncodedString()],
                ["name": "Pasted text", "mimeType": "text/plain", "text": "a long paste"],
            ],
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["copied"] as? Int == 2)
        let items = try #require(effects.copied.first)
        #expect(effects.copied.count == 1)
        #expect(items.count == 3)
        // The text first, alone.
        #expect(items[0].string(forType: .string) == "look at these")
        #expect(items[0].string(forType: .fileURL) == nil)
        // The image: its named copy, its bytes and a TIFF.
        let image = try #require(Self.fileURL(items[1]))
        // Its own plain name, so a paste anywhere shows "chart.png".
        #expect(image.lastPathComponent == "chart.png")
        #expect(try Data(contentsOf: image) == Self.png)
        #expect(items[1].data(forType: .png) == Self.png)
        #expect(items[1].data(forType: .tiff).flatMap(NSImage.init(data:)) != nil)
        // The text item: a .txt file holding exactly its text.
        let text = try #require(Self.fileURL(items[2]))
        #expect(text.lastPathComponent == "Pasted text.txt")
        #expect(try String(contentsOf: text, encoding: .utf8) == "a long paste")
        // Each in a folder named by its bytes' short hash, in the copies folder.
        for file in [image, text] {
            let place = file.deletingLastPathComponent()
            #expect(place.lastPathComponent.count == 8)
            let hex = place.lastPathComponent.allSatisfy { $0.isHexDigit }
            #expect(hex)
            #expect(place.deletingLastPathComponent().lastPathComponent == "Composer Copies")
        }
    }

    @Test func twoAttachmentsOfOneNameKeepItAndLandApart() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)

        let reply = await Self.ask(model, [
            "text": "",
            "items": [
                ["name": "report.pdf", "mimeType": "application/pdf", "data": Data("%PDF-1.4 one".utf8).base64EncodedString()],
                ["name": "report.pdf", "mimeType": "application/pdf", "data": Data("%PDF-1.4 two".utf8).base64EncodedString()],
                // A name with folders and a control character is made one plain file name.
                ["name": "../a/b\u{7}c.txt", "mimeType": "text/plain", "text": "x"],
                ["name": "...", "mimeType": "text/plain", "text": "y"],
            ],
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let items = try #require(effects.copied.first)
        #expect(items.count == 4)
        let files = items.compactMap(Self.fileURL)
        #expect(files.count == 4)
        #expect(files[0].lastPathComponent == "report.pdf")
        #expect(files[1].lastPathComponent == "report.pdf")
        #expect(files[0].deletingLastPathComponent() != files[1].deletingLastPathComponent())
        #expect(try Data(contentsOf: files[0]) == Data("%PDF-1.4 one".utf8))
        #expect(try Data(contentsOf: files[1]) == Data("%PDF-1.4 two".utf8))
        #expect(files[2].lastPathComponent == "a-b-c.txt")
        #expect(files[3].lastPathComponent == "Attachment.txt")
    }

    @Test func anAttachedPathIsItsOwnFileAndAMissingOrDeniedOneIsLeftOut() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)
        let attached = folder.appendingPathComponent("report.pdf")
        try Data("%PDF-1.4".utf8).write(to: attached)
        let secret = folder.appendingPathComponent("server.pem")
        try Data("key".utf8).write(to: secret)

        let reply = await Self.ask(model, [
            "text": "",
            "items": [
                ["name": "report.pdf", "mimeType": "application/pdf", "path": attached.path],
                ["name": "gone.pdf", "mimeType": "application/pdf", "path": folder.appendingPathComponent("gone.pdf").path],
                ["name": "server.pem", "mimeType": "", "path": secret.path],
            ],
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        #expect((reply["value"] as? [String: Any])?["skipped"] as? Int == 2)
        // The reply names each kept file by its item, so the page knows its copy again on a paste.
        let written = try #require((reply["value"] as? [String: Any])?["files"] as? [[String: Any]])
        #expect(written.count == (reply["value"] as? [String: Any])?["copied"] as? Int)
        let named = written.allSatisfy { ($0["item"] as? Int) != nil && !(($0["name"] as? String) ?? "").isEmpty }
        #expect(named)
        let items = try #require(effects.copied.first)
        #expect(items.count == 1)
        let file = try #require(Self.fileURL(items[0]))
        #expect(file.resolvingSymlinksInPath().path == attached.resolvingSymlinksInPath().path)

        // Nothing kept and no text: nothing is written.
        let none = await Self.ask(model, ["text": "", "items": [["name": "gone", "mimeType": "", "path": "/nonexistent/gone"]]])
        #expect(Self.errorCode(none) == AgentPaneReplyError.openFailed.rawValue)
        #expect(effects.copied.count == 1)
    }

    @Test func aRemoteChatPutsNoneOfThisMacsFilesOnThePasteboard() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)
        model.remoteChat = true
        let attached = folder.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: attached)

        let reply = await Self.ask(model, [
            "text": "hello",
            "items": [["name": "notes.txt", "mimeType": "text/plain", "path": attached.path]],
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let items = try #require(effects.copied.first)
        #expect(items.count == 1)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].string(forType: .fileURL) == nil)
    }

    @Test func anSVGIsCopiedOnlyAsItsRebuiltForm() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg"><script>location='cmux://x'</script><rect width="1" height="1"/></svg>"#

        let reply = await Self.ask(model, [
            "text": "",
            "items": [
                ["name": "drawing.svg", "mimeType": "image/svg+xml", "data": Data(svg.utf8).base64EncodedString()],
                ["name": "drawing.svg", "mimeType": "image/svg+xml", "text": svg],
            ],
        ])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let items = try #require(effects.copied.first)
        #expect(items.count == 2)
        for item in items {
            let file = try #require(Self.fileURL(item))
            let written = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(file.pathExtension == "svg")
            #expect(!written.contains("<script") && !written.contains("cmux://"), "\(written)")
            #expect(written.contains("<rect"))
        }
    }

    @Test func withoutTheCopyKeyNothingIsWritten() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (model, effects) = Self.model(folder)

        let reply = await Self.ask(model, [
            "text": "x", "items": [["name": "a.txt", "mimeType": "text/plain", "text": "a"]],
        ], click: false)
        #expect(Self.errorCode(reply) == AgentPaneReplyError.gestureRequired.rawValue)
        #expect(effects.copied.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: model.replyLinks.imageFolder.appendingPathComponent("Composer Copies").path))
    }
}
