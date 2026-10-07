import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Local video and audio in replies and tool output: the host checks the path like a reply image,
/// then lets the page play the file by an unguessable `cmux-agent://pane/__media/` URL that the
/// pane's scheme handler serves in byte ranges. The page never names a file itself.
@MainActor
@Suite struct AgentPaneReplyMediaTests {
    static func load(_ model: AgentPaneModel, _ src: String) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "media.load", "params": ["src": src]] as [String: Any]))
    }

    @Test func aVideoInsideTheRootsGetsAPlayableURLAndNothingElseDoes() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "reply-media-\(UUID().uuidString)")
        let root = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(repeating: 7, count: 64).write(to: root.appending(path: "demo.mp4"))
        try Data(repeating: 7, count: 64).write(to: root.appending(path: "notes.txt"))
        try Data(repeating: 7, count: 64).write(to: base.appending(path: "outside.mp4"))
        let model = AgentPaneReplyImageTests.model(root: root)

        let src = try #require(AgentPaneReplyImageTests.src(await Self.load(model, root.appending(path: "demo.mp4").path)))
        #expect(src.hasPrefix("cmux-agent://pane/__media/"))
        #expect(src.hasSuffix(".mp4"))
        #expect(!src.contains("demo"))
        // The same file keeps its URL, so a re-render does not restart playback.
        #expect(AgentPaneReplyImageTests.src(await Self.load(model, "demo.mp4")) == src)
        #expect(AgentPaneSchemeHandler.mediaFile(for: try #require(URL(string: src)))?.lastPathComponent == "demo.mp4")

        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, root.appending(path: "notes.txt").path)) == "link.media_refused")
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, base.appending(path: "outside.mp4").path)) == "link.path_outside_roots")
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, "https://example.com/demo.mp4")) == "link.media_refused")
        #expect(AgentPaneSchemeHandler.mediaFile(for: try #require(URL(string: "cmux-agent://pane/__media/0000.mp4"))) == nil)
    }

    @Test func theSchemeHandlerServesAGrantedFileInByteRanges() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "media-\(UUID().uuidString).mp4")
        try Data((0 ..< 100).map { UInt8($0) }).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let part = try #require(AgentPaneSchemeHandler.mediaSlice(of: file, range: "bytes=10-19"))
        #expect(part.status == 206)
        #expect(part.data == Data((10 ..< 20).map { UInt8($0) }))
        #expect(part.headers["Content-Range"] == "bytes 10-19/100")
        #expect(part.headers["Content-Type"] == "video/mp4")
        #expect(part.headers["Accept-Ranges"] == "bytes")
        #expect(part.headers["Content-Length"] == "10")

        let tail = try #require(AgentPaneSchemeHandler.mediaSlice(of: file, range: "bytes=90-"))
        #expect(tail.headers["Content-Range"] == "bytes 90-99/100")
        let whole = try #require(AgentPaneSchemeHandler.mediaSlice(of: file, range: nil))
        #expect(whole.status == 200)
        #expect(whole.data.count == 100)
        // A range past the end is unsatisfiable.
        #expect(AgentPaneSchemeHandler.mediaSlice(of: file, range: "bytes=200-")?.status == 416)
    }

    @Test func theParamsContractTakesOneSource() {
        func request(_ params: [String: Any]) -> AgentPaneRequest {
            AgentPaneRequest(body: ["method": "media.load", "params": params] as [String: Any])
        }
        #expect(request(["src": "/a.mp4"]) == .reply(.loadMedia("/a.mp4")))
        #expect(request(["src": "/a.mp4", "autoplay": true]) == .unsupported("media.load"))
        #expect(request(["src": ""]) == .unsupported("media.load"))
    }
}
