import AppKit
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Projection windows (``WebProjection``): a page in a bound window loads from that window's server,
/// a page in any other window keeps its own files, and unbinding gives the window its pages back.
@MainActor
struct WebProjectionTests {
    @Test func onlyTheProjectionWindowsPagesLoadFromItsServer() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("bundled".utf8).write(to: bundled.appending(path: PageDescriptor.markdown.entry))
        let root = try #require(URL(string: "http://127.0.0.1:4291/"))
        let projection = window(), main = window()
        let projected = webView(in: projection), untouched = webView(in: main)
        defer { WebProjection.shared.unbind(projection) }

        let handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        handler.liveOverride = { WebDevOverride() }
        handler.fetchDevServer = { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
            return response.map { (Data("served by \(url.port ?? 0)".utf8), $0) }
        }

        #expect(try await body(handler, projected) == "bundled")
        #expect(WebProjection.shared.bind(projection, server: PageDevServer(root: root)) != nil)
        #expect(WebProjection.shared.server(for: projected)?.root == root)
        #expect(WebProjection.shared.server(for: untouched) == nil)
        #expect(try await body(handler, projected) == "served by 4291")
        #expect(try await body(handler, untouched) == "bundled")

        WebProjection.shared.unbind(projection)
        #expect(WebProjection.shared.server(for: projected) == nil)
        #expect(try await body(handler, projected) == "bundled")
    }

    @Test func theProjectionServerReplacesOnlyTheOverridesServer() throws {
        let root = try #require(URL(string: "http://127.0.0.1:4292/"))
        let projection = window()
        let projected = webView(in: projection)
        defer { WebProjection.shared.unbind(projection) }
        WebProjection.shared.bind(projection, server: PageDevServer(root: root))
        #expect(WebProjection.shared.override(for: projected).server?.root == root)
        #expect(WebProjection.shared.override(for: nil) == WebDevOverride.current)
        #expect(WebProjection.shared.isActive)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func webView(in window: NSWindow) -> WKWebView {
        // webview-allow: a test view that is never loaded, only placed in a window
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        return view
    }

    private func body(_ handler: PageSchemeHandler, _ webView: WKWebView) async throws -> String {
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/"))
        let reply = try #require(await handler.reply(to: url, webView: webView))
        return String(decoding: reply.body, as: UTF8.self)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "web-projection-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }
}
