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

    static let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 32)

    static func model(_ setting: AgentPaneReplySetting = .fallback, fetch: AgentPaneReplyImageTests.FakeFetch) -> AgentPaneModel {
        let model = AgentPaneReplyImageTests.model(root: URL(fileURLWithPath: NSTemporaryDirectory()), setting)
        model.replyLinks.mediaFetcher = fetch
        return model
    }

    /// Web media (a GitHub user attachment, a CI artifact link) follows `agentPane.images.remote`
    /// and the host fetch's network rules; the bytes become a local copy the pane plays like a file.
    @Test func aWebVideoFollowsTheImageSettingAndPlaysFromACheckedCopy() async throws {
        let url = "https://github.com/user-attachments/assets/2f0c0b4e-1d2a-4c4e-9d55-\(UUID().uuidString.prefix(12))"
        // never: no fetch at all.
        var fetch = AgentPaneReplyImageTests.FakeFetch(Self.mp4)
        var model = Self.model(AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .never), fetch: fetch)
        model.transport.gestures.record()
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, url)) == "link.media_refused")
        #expect(fetch.asked.isEmpty)
        // click (default): only after a gesture.
        fetch = AgentPaneReplyImageTests.FakeFetch(Self.mp4)
        model = Self.model(fetch: fetch)
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, url)) == "link.gesture_required")
        #expect(fetch.asked.isEmpty)
        model.transport.gestures.record()
        let src = try #require(AgentPaneReplyImageTests.src(await Self.load(model, url)))
        #expect(src.hasPrefix("cmux-agent://pane/__media/"))
        #expect(src.hasSuffix(".mp4"))
        let media = try #require(URL(string: src))
        let copy = try #require(AgentPaneSchemeHandler.mediaFile(for: media))
        #expect(try Data(contentsOf: copy) == Self.mp4)
        // The same link plays the same copy: no second fetch, no second gesture.
        #expect(AgentPaneReplyImageTests.src(await Self.load(model, url)) == src)
        #expect(fetch.asked.count == 1)
        // Bytes that are not video or audio are refused, whatever the link says.
        fetch = AgentPaneReplyImageTests.FakeFetch(Data("<html>".utf8))
        model = Self.model(AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .always), fetch: fetch)
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, "https://cdn.example/clip-\(UUID().uuidString).mp4")) == "link.media_refused")
        // http is never fetched.
        #expect(AgentPaneReplyLinkTests.code(await Self.load(model, "http://cdn.example/clip.mp4")) == "link.media_refused")
        #expect(fetch.asked.count == 1)
    }

    @Test func theMediaTypeComesFromTheBytes() {
        func box(_ brand: String) -> Data { Data([0, 0, 0, 0x18]) + Data(("ftyp" + brand).utf8) + Data(repeating: 0, count: 16) }
        #expect(AgentPaneMediaGrants.sniff(box("isom")) == "mp4")
        #expect(AgentPaneMediaGrants.sniff(box("qt  ")) == "mov")
        #expect(AgentPaneMediaGrants.sniff(box("M4A ")) == "m4a")
        #expect(AgentPaneMediaGrants.sniff(Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0])) == "webm")
        #expect(AgentPaneMediaGrants.sniff(Data("ID3".utf8) + Data(repeating: 0, count: 8)) == "mp3")
        #expect(AgentPaneMediaGrants.sniff(Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WAVE".utf8)) == "wav")
        #expect(AgentPaneMediaGrants.sniff(Data("<!doctype html>".utf8)) == nil)
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
