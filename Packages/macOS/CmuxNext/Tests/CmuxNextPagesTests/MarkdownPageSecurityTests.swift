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

        #expect(try scriptSource(in: policy) == "script-src 'self' 'wasm-unsafe-eval'")
    }

    @Test func devServerAllowsViteInlinePreamble() throws {
        let server = try #require(PageDevServer.resolve(
            environment: [PageDevServer.variable: "http://127.0.0.1:4190/"],
            allowsDevServer: true
        ))

        #expect(try scriptSource(in: server.csp(for: .markdown).header) == "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'")
    }

    private func scriptSource(in policy: String) throws -> String {
        try #require(
            policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("script-src ") }
        )
    }
}
