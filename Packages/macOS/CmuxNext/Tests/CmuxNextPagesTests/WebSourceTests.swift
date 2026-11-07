@testable import CmuxNextPages
import Foundation
import Testing

/// "Show what's live" (docs/cmux-next/hot-reload.md, Planned: "Show what's live"): in DEV and NIGHTLY a page's
/// document names where it was served from, in a tag in its head and to the host (the window's
/// source chip): the dev server, the overlay at its commit, a web update at its commit, or the bundle. Other
/// files, and builds that do not show it, carry no tag.
@MainActor
struct WebSourceTests {
    private nonisolated static let token = "0123456789abcdef0123456789abcdef01234567"
    private nonisolated static let page = "<!doctype html><html><head><title>t</title></head><body></body></html>"

    @Test func theDevServersDocumentNamesTheServer() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try write(Self.page, to: bundled.appending(path: PageDescriptor.markdown.entry))
        let root = try #require(URL(string: "http://127.0.0.1:4200/"))
        let handler = Self.handler(bundled)
        handler.liveOverride = { WebDevOverride(server: PageDevServer(root: root, token: Self.token)) }
        handler.fetchDevServer = { request in Self.proven(request, body: Self.page) }
        var told: [WebSource] = []
        handler.onWebSource = { told.append($0) }
        #expect(try await source(handler) == "dev-server http://127.0.0.1:4200/")
        // The host is told the same source (a Chromium page keeps it as PageWebView.webSource).
        #expect(told == [.devServer(root)])

        // A script from the same server is not touched.
        let script = try #require(URL(string: PageDescriptor.markdown.origin + "/src/main.tsx"))
        handler.fetchDevServer = { request in Self.proven(request, body: "export {}", contentType: "text/javascript") }
        let reply = try #require(await handler.reply(to: script))
        #expect(String(decoding: reply.body, as: UTF8.self) == "export {}")
    }

    @Test func theOverlaysDocumentNamesItsCommit() async throws {
        let bundled = try temporaryDirectory()
        let overlay = try temporaryDirectory()
        defer { for dir in [bundled, overlay] { try? FileManager.default.removeItem(at: dir) } }
        try write(Self.page, to: bundled.appending(path: PageDescriptor.markdown.entry))
        try write(Self.page, to: overlay.appending(path: "\(bundled.lastPathComponent)/\(PageDescriptor.markdown.entry)"))
        let handler = Self.handler(bundled)
        let manifest = Data(#"{"stamp":"1","commit":"55f310cd597d","surfaces":["pages"]}"#.utf8)
        handler.liveOverride = { WebDevOverride(overlay: overlay, stamp: manifest) }
        #expect(try await source(handler) == "overlay 55f310cd597d")
        // An install with no known commit names none.
        let unknown = Data(#"{"stamp":"1","commit":"unknown"}"#.utf8)
        handler.liveOverride = { WebDevOverride(overlay: overlay, stamp: unknown) }
        #expect(try await source(handler) == "overlay")
    }

    @Test func aWebUpdatesDocumentNamesItsCommit() async throws {
        let bundled = try temporaryDirectory()
        let tree = try temporaryDirectory()
        defer { for dir in [bundled, tree] { try? FileManager.default.removeItem(at: dir) } }
        try write(Self.page, to: bundled.appending(path: PageDescriptor.markdown.entry))
        try write(Self.page, to: tree.appending(path: "fixture/page/\(PageDescriptor.markdown.entry)"))
        let updates = WebBundleOverlay(bases: [.init(bundled: bundled.path, output: "fixture/page")])
        updates.activate(tree)
        updates.name(tree, commit: "8c52aca86c99")
        let handler = Self.handler(bundled)
        handler.webUpdates = updates
        #expect(try await source(handler) == "web-update 8c52aca86c99")
        var told: [WebSource] = []
        handler.onWebSource = { told.append($0) }
        _ = try await source(handler)
        updates.activate(nil)
        #expect(try await source(handler) == "bundle")
        #expect(told == [.webUpdate(commit: "8c52aca86c99"), .bundle])
    }

    @Test func theBundlesDocumentSaysBundleAndABuildThatHidesItSaysNothing() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try write(Self.page, to: bundled.appending(path: PageDescriptor.markdown.entry))
        let handler = Self.handler(bundled)
        #expect(try await source(handler) == "bundle")
        handler.marksWebSource = false
        #expect(try await source(handler) == nil)
        #expect(try await body(handler) == Self.page)
    }

    /// The tag goes inside the head, never before the doctype (quirks mode), with its values escaped.
    @Test func theTagGoesInTheHeadEscaped() throws {
        let marked = String(decoding: WebSource.bundle.marked(Data(Self.page.utf8)), as: UTF8.self)
        #expect(marked.hasPrefix("<!doctype html><html><head><meta name=\"cmux-web-source\" content=\"bundle\""))
        #expect(marked.hasSuffix("<title>t</title></head><body></body></html>"))
        let attributes = String(decoding: WebSource.bundle.marked(Data(#"<HEAD lang="en"><p>"#.utf8)), as: UTF8.self)
        #expect(attributes.hasPrefix(#"<HEAD lang="en"><meta name="cmux-web-source""#))
        // `<header>` is not the head; with no head or html tag the tag goes at the end.
        let noHead = String(decoding: WebSource.bundle.marked(Data("<header>x</header>".utf8)), as: UTF8.self)
        #expect(noHead.hasPrefix("<header>x</header><meta "))
        let url = try #require(URL(string: "http://127.0.0.1:4200/?a=1&b=2"))
        #expect(WebSource.devServer(url).meta.contains(#"content="dev-server http://127.0.0.1:4200/?a=1&amp;b=2""#))
        #expect(WebSource.escape(#"<"x">"#) == "&lt;&quot;x&quot;&gt;")
        #expect(WebSource.commit("abc; <x>") == nil)
        #expect(WebSource.commit(String(repeating: "a", count: 41)) == nil)
    }

    private static func handler(_ bundled: URL) -> PageSchemeHandler {
        let handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        handler.webUpdates = WebBundleOverlay(bases: [])
        handler.marksWebSource = true
        return handler
    }

    /// The `content` of the document's source tag, nil for none.
    private func source(_ handler: PageSchemeHandler) async throws -> String? {
        let html = try await body(handler)
        guard let start = html.range(of: "<meta name=\"cmux-web-source\" content=\"") else { return nil }
        let rest = html[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    private func body(_ handler: PageSchemeHandler) async throws -> String {
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/"))
        let reply = try #require(await handler.reply(to: url))
        return String(decoding: reply.body, as: UTF8.self)
    }

    private nonisolated static func proven(_ request: URLRequest, body: String,
                                           contentType: String = "text/html") -> (Data, HTTPURLResponse)? {
        guard let url = request.url, let nonce = request.value(forHTTPHeaderField: PageDevServer.nonceHeader) else { return nil }
        let headers = [PageDevServer.proofHeader: PageDevServer.proof(token: token, nonce: nonce), "Content-Type": contentType]
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers).map { (Data(body.utf8), $0) }
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "web-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
