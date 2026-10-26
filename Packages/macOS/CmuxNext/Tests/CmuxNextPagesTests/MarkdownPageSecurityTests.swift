@testable import CmuxNextPages
import Foundation
import Testing

@MainActor
struct MarkdownPageSecurityTests {
    @Test func responseBlocksInlineScript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-page-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Markdown</title>".utf8)
            .write(to: root.appendingPathComponent(PageDescriptor.markdown.entry))

        let handler = PageSchemeHandler(page: .markdown, root: root, devServer: nil)
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/"))
        let reply = try #require(await handler.reply(to: url))
        let policy = try #require(reply.response.value(forHTTPHeaderField: "Content-Security-Policy"))

        #expect(try scriptSource(in: policy) == "script-src 'self' cmux-page://cmux.shared 'wasm-unsafe-eval'")
    }

    /// The Markdown page renders repository files, so the shared origin its `script-src` names must
    /// serve only bundled script: no document, nothing from the page's dynamic prefixes (a
    /// repository file under `__asset`), and nothing to another origin.
    @Test func sharedOriginServesOnlyBundledScriptToTheMarkdownPage() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-page-shared-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("markdown", isDirectory: true)
        let shared = base.appendingPathComponent("_shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared.appendingPathComponent(MarkdownPageResource.asset),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("export const React = 1".utf8).write(to: shared.appendingPathComponent("react-1a2b.js"))
        try Data("<script>alert(1)</script>".utf8).write(to: shared.appendingPathComponent("evil.html"))
        let repositoryFiles = RepositoryFiles()
        let handler = PageSchemeHandler(page: .markdown, root: root, dynamicSource: repositoryFiles, devServer: nil,
                                        sharedRoot: shared)
        let origin = PageDescriptor.markdown.origin

        let chunk = try #require(URL(string: PageID.sharedOrigin + "/react-1a2b.js"))
        let reply = try #require(await handler.sharedReply(to: chunk, origin: origin))
        #expect(reply.response.statusCode == 200)
        #expect(reply.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == origin)

        let document = try #require(URL(string: PageID.sharedOrigin + "/evil.html"))
        #expect(await handler.sharedReply(to: document, origin: origin) == nil)
        let asset = try #require(URL(string: PageID.sharedOrigin + "/\(MarkdownPageResource.asset)/payload.js"))
        #expect(await handler.sharedReply(to: asset, origin: origin) == nil)
        #expect(repositoryFiles.asked == 0, "a shared request reached the page's repository files")
        #expect(await handler.sharedReply(to: chunk, origin: "cmux-page://com.example.notes") == nil)
    }

    @Test func devServerAllowsViteInlinePreamble() throws {
        let server = try #require(PageDevServer.resolve(
            environment: [PageDevServer.variable: "http://127.0.0.1:4190/"],
            allowsDevServer: true
        ))

        #expect(try scriptSource(in: server.csp(for: .markdown).header)
            == "script-src 'self' 'unsafe-inline' cmux-page://cmux.shared 'wasm-unsafe-eval'")
    }

    /// A Markdown page's repository files: answers every request with script, and counts them.
    private final class RepositoryFiles: PageDynamicResourceSource {
        var asked = 0
        func resource(for request: PageResourceRequest) async -> PageResource? {
            asked += 1
            return PageResource(data: Data("alert(1)".utf8), mimeType: "text/javascript")
        }
    }

    private func scriptSource(in policy: String) throws -> String {
        try #require(
            policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("script-src ") }
        )
    }
}
