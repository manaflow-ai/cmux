@testable import CmuxNextAgentPane
@testable import CmuxNextPages
import Foundation
import Testing

/// A sent video plays in place on the shared page host (`cmux-page://cmux.agent`, #34726): the page's
/// CSP lets it play media from its own origin, and the page host serves a granted file at
/// `__media/<token>` in byte ranges, as the pane's own host does at `cmux-agent://pane/__media/`.
@MainActor
struct AgentPageMediaResourceTests {
    private static func clip(_ bytes: Int) throws -> (folder: URL, file: URL, data: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-page-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("clip.mov")
        let data = Data((0 ..< bytes).map { UInt8($0 % 251) })
        try data.write(to: file)
        return (folder, file, data)
    }

    private static func handler(root: URL) -> PageSchemeHandler {
        let handler = PageSchemeHandler(page: .agent, root: root, dynamicSource: AgentPageMediaResource.shared, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        return handler
    }

    @Test func theAgentPagePlaysMediaFromItsOwnOrigin() {
        let header = PageDescriptor.agent.csp.header
        #expect(header.contains("media-src 'self'"), "\(header)")
        #expect(PageDescriptor.agent.dynamicPrefixes.contains("__media"))
    }

    @Test func aGrantedVideoStreamsInRangesFromThePageHost() async throws {
        let (folder, file, data) = try Self.clip(100)
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = AgentPaneMediaGrants.shared.grant(file)
        #expect(own.hasPrefix("cmux-agent://pane/__media/"))
        // The pane's own host keeps its URL; the page host gets the same token on its origin.
        #expect(AgentPaneMediaGrants.src(own, on: AgentPaneSource.bundledOrigin) == own)
        let src = AgentPaneMediaGrants.src(own, on: AgentPaneMediaGrants.pageOrigin)
        #expect(src.hasPrefix("cmux-page://cmux.agent/__media/") && src.hasSuffix(".mov"), "\(src)")
        let url = try #require(URL(string: src))
        #expect(AgentPaneMediaGrants.shared.file(for: url) == file)

        let handler = Self.handler(root: folder)
        let ranged = try #require(await handler.reply(to: url, range: "bytes=10-19"))
        #expect(ranged.response.statusCode == 206)
        #expect(ranged.response.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/100")
        #expect(ranged.response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(ranged.response.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        #expect(ranged.body == data.subdata(in: 10 ..< 20))

        let open = try #require(await handler.reply(to: url, range: "bytes=90-"))
        #expect(open.response.statusCode == 206)
        #expect(open.response.value(forHTTPHeaderField: "Content-Range") == "bytes 90-99/100")
        #expect(open.body == data.subdata(in: 90 ..< 100))

        let whole = try #require(await handler.reply(to: url))
        #expect(whole.response.statusCode == 200)
        #expect(whole.body == data)

        let past = try #require(await handler.reply(to: url, range: "bytes=200-"))
        #expect(past.response.statusCode == 416)
        #expect(past.response.value(forHTTPHeaderField: "Content-Range") == "bytes */100")
    }

    @Test func aTokenTheHostNeverGrantedIsNotFound() async throws {
        let (folder, _, _) = try Self.clip(10)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "cmux-page://cmux.agent/__media/00000000000000000000000000000000.mov"))
        let reply = try #require(await Self.handler(root: folder).reply(to: url, range: "bytes=0-"))
        #expect(reply.response.statusCode == 404)
        #expect(reply.body.isEmpty)
        // Chromium asks for whole bodies, which this route never reads: a 404, not the file.
        let request = try #require(PageSchemeHandler.dynamicRequest(for: url, page: .agent))
        #expect(await PageSchemeHandler.dynamicResponse(to: request, source: AgentPageMediaResource.shared).status == 404)
    }
}
