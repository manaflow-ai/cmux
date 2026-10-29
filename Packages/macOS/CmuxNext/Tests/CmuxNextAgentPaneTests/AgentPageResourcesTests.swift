@testable import CmuxNextAgentPane
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// The agent page's chart and diagram libraries, its reply media and its render frame come from the
/// page host (``AgentPageResources`` behind ``PageDescriptor/agent``'s dynamic prefixes), as the
/// deleted `cmux-agent://pane` handler served them: before, the page host answered none of them,
/// so reply video, diagrams and render cards did not load in any configuration.
@MainActor
struct AgentPageResourcesTests {
    private let folder: URL
    private let clip: URL
    private let clipBytes = Data((0..<100).map { UInt8($0) })

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "agent-resources-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mermaid()".utf8).write(to: folder.appending(path: "mermaid.min.js"))
        try Data("<!doctype html><title>Agent</title>".utf8).write(to: folder.appending(path: "index.html"))
        clip = folder.appending(path: "clip.mp4")
        try clipBytes.write(to: clip)
    }

    /// The page host's WebKit handler for the agent page, its resources from `resources`.
    private func handler(_ resources: AgentPageResources) -> PageSchemeHandler {
        PageSchemeHandler(page: .agent, root: folder, dynamicSource: resources, devServer: nil)
    }

    private func header(_ reply: PageSchemeHandler.Reply, _ name: String) -> String? {
        reply.response.value(forHTTPHeaderField: name)
    }

    @Test func aLibraryIsServedOnThePagesOwnOrigin() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = AgentPageResources(libraryFolder: folder, grants: AgentPaneMediaGrants(), runner: BackgroundWork(label: "test.agent-page"))
        let handler = handler(resources)
        let url = try #require(URL(string: "cmux-page://cmux.agent/__lib/mermaid.js"))
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.response.statusCode == 200)
        #expect(String(decoding: reply.body, as: UTF8.self) == "mermaid()")
        #expect(header(reply, "Content-Type") == "text/javascript")
        // A library the pane does not load, and a library path with more parts, are 404s.
        for other in ["cmux-page://cmux.agent/__lib/other.js", "cmux-page://cmux.agent/__lib/x/mermaid.js"] {
            let otherURL = try #require(URL(string: other))
            let missing = try #require(await handler.reply(to: otherURL))
            #expect(missing.response.statusCode == 404, "\(other)")
        }
    }

    @Test func grantedMediaIsServedInByteRanges() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let grants = AgentPaneMediaGrants()
        let resources = AgentPageResources(libraryFolder: nil, grants: grants, runner: BackgroundWork(label: "test.agent-page"))
        let handler = handler(resources)
        let src = grants.grant(clip)
        #expect(src.hasPrefix("cmux-page://cmux.agent/__media/"))
        let url = try #require(URL(string: src))
        #expect(grants.file(for: url) == clip)

        let whole = try #require(await handler.reply(to: url))
        #expect(whole.response.statusCode == 200)
        #expect(whole.body == clipBytes)
        #expect(header(whole, "Content-Type") == "video/mp4")
        #expect(header(whole, "Accept-Ranges") == "bytes")

        let part = try #require(await handler.reply(to: url, range: "bytes=10-19"))
        #expect(part.response.statusCode == 206)
        #expect(part.body == clipBytes.subdata(in: 10..<20))
        #expect(header(part, "Content-Range") == "bytes 10-19/100")

        let tail = try #require(await handler.reply(to: url, range: "bytes=-5"))
        #expect(tail.body == clipBytes.subdata(in: 95..<100))
        #expect(header(tail, "Content-Range") == "bytes 95-99/100")

        let past = try #require(await handler.reply(to: url, range: "bytes=200-"))
        #expect(past.response.statusCode == 416)
        #expect(header(past, "Content-Range") == "bytes */100")

        // A token nothing granted is a 404, and so is the old host's media URL on any handler.
        let unknownURL = try #require(URL(string: "cmux-page://cmux.agent/__media/0123.mp4"))
        let unknown = try #require(await handler.reply(to: unknownURL))
        #expect(unknown.response.statusCode == 404)
        let oldHost = try #require(URL(string: "cmux-agent://pane/__media/" + url.lastPathComponent))
        #expect(grants.file(for: oldHost) == nil)

        // Chromium's resources carry no Range header: a small file plays whole there.
        let request = try #require(PageSchemeHandler.dynamicRequest(for: url, page: .agent))
        let chromium = await PageSchemeHandler.dynamicResponse(to: request, source: resources)
        #expect(chromium.status == 200)
        #expect(chromium.body == clipBytes)
    }

    /// A web-dev.json server serves the page's files, never its generated resources: those stay the
    /// page host's in the dev loop too.
    @Test func aDevServerLeavesTheGeneratedResourcesToThePageHost() throws {
        let config = Data(#"{"server": "http://127.0.0.1:4181/"}"#.utf8)
        let server = try #require(WebDevOverride.parse(config, home: URL(fileURLWithPath: "/")).server)
        for path in ["/__lib/mermaid.js", "/__media/0123.mp4", "/__render/frame"] {
            let url = try #require(URL(string: PageDescriptor.agent.origin + path))
            #expect(server.url(for: url, page: .agent) == nil, "\(path)")
        }
    }

    @Test func aRangeHeaderIsReadAsBefore() {
        func range(_ header: String) -> [Int]? { AgentPageResources.byteRange(header, size: 10).map { [$0.0, $0.1] } }
        #expect(range("bytes=0-1") == [0, 1])
        #expect(range("bytes=4-") == [4, 9])
        #expect(range("bytes=-3") == [7, 9])
        #expect(AgentPageResources.byteRange("bytes=0-1,4-5", size: 10) == nil)
        #expect(AgentPageResources.byteRange("items=0-1", size: 10) == nil)
        #expect(AgentPageResources.byteRange("bytes=5-2", size: 10) == nil)
    }

    @Test func theRenderFrameRunsInItsOwnSandboxedPolicy() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = AgentPageResources(libraryFolder: nil, grants: AgentPaneMediaGrants(), runner: BackgroundWork(label: "test.agent-page"))
        let url = try #require(URL(string: AgentPaneRenderFrame.source))
        #expect(url.absoluteString == PageDescriptor.agent.origin + "/__render/frame")
        let reply = try #require(await handler(resources).reply(to: url))
        #expect(reply.response.statusCode == 200)
        #expect(reply.body == AgentPaneRenderFrame.document)
        let policy = try #require(header(reply, "Content-Security-Policy"))
        // Always an opaque origin, whatever frames it: the page's bridge and acpmux stay out of reach.
        #expect(policy.hasPrefix("sandbox allow-scripts; "))
        #expect(policy.hasSuffix(AgentPaneRenderFrame.policy))
        // The page's own documents keep the page's policy.
        let index = try #require(URL(string: "cmux-page://cmux.agent/index.html"))
        let page = try #require(await handler(resources).reply(to: index))
        #expect(header(page, "Content-Security-Policy") == PageDescriptor.agent.csp.header)
        // Chromium serves only the page's policy, so it never serves the frame.
        let request = try #require(PageSchemeHandler.dynamicRequest(for: url, page: .agent))
        #expect(await PageSchemeHandler.dynamicResponse(to: request, source: resources).status == 404)
        // The page frames this one document and plays only its own media.
        let csp = PageDescriptor.agent.csp.header
        #expect(csp.contains("frame-src \(AgentPaneRenderFrame.source) "))
        #expect(csp.contains("media-src 'self'"))
        #expect(PageDescriptor.agent.dynamicPrefixes == ["__lib", "__media", "__render"])
    }
}
