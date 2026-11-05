import AppKit
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Projection windows (``WebProjection``): a page in a projection's window loads from that window's
/// server, a page in any other window keeps its own files, and a test run finds its projection.
@MainActor
struct WebProjectionTests {
    @Test func onlyTheProjectionWindowsPagesLoadFromItsServer() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("bundled".utf8).write(to: bundled.appending(path: PageDescriptor.markdown.entry))
        let projection = WebProjection(), handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        let projectionWindow = window(), mainWindow = window()
        let projected = webView(in: projectionWindow), untouched = webView(in: mainWindow)
        handler.liveOverride = { WebDevOverride() }
        handler.projection = projection
        handler.fetchDevServer = { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
            return response.map { (Data("served by \(url.port ?? 0)".utf8), $0) }
        }

        #expect(try await body(handler, projected) == "bundled")
        let opened = try projection.open(server: "http://127.0.0.1:4291/", worktree: "~/wt", test: nil)
        projection.windowID = { $0 === projectionWindow ? opened.windowID : "main" }
        projection.isOpen = { _ in true }
        #expect(projection.server(for: projected)?.root.port == 4291)
        #expect(projection.server(for: untouched) == nil)
        #expect(try await body(handler, projected) == "served by 4291")
        #expect(try await body(handler, untouched) == "bundled")
        #expect(projection.override(for: projected).server?.root.port == 4291)
        #expect(projection.override(for: untouched) == WebDevOverride.current)

        projection.isOpen = { _ in false }
        projection.windowID = { _ in nil } // the window closed
        #expect(projection.server(for: projected) == nil)
        #expect(!projection.isActive)
    }

    @Test func openRefusesARemoteServerAndKeepsTheWorktree() throws {
        let projection = WebProjection()
        #expect(throws: WebProjection.Refusal(message: WebProjection.notLoopback)) {
            try projection.open(server: "http://10.0.0.2:4290/", worktree: nil, test: nil)
        }
        let opened = try projection.open(server: nil, worktree: "/src/wt", test: "")
        #expect(opened.server.root.absoluteString == WebProjection.defaultServer)
        #expect(opened.worktree == "/src/wt")
        #expect(opened.test == nil)
        #expect(WebProjection.workspaceName(opened.worktree).contains("wt"))
    }

    @Test func aTestRunGoesToTheActiveProjectionElseTheNewestOpenOne() throws {
        let projection = WebProjection()
        #expect(throws: WebProjection.Refusal(message: WebProjection.noProjection)) { try projection.testRun(in: nil, test: nil) }
        let first = try projection.open(server: nil, worktree: "/a", test: "bun test a")
        let second = try projection.open(server: nil, worktree: "/b", test: nil)
        projection.isOpen = { _ in true }
        #expect(throws: WebProjection.Refusal(message: WebProjection.noTest)) { try projection.testRun(in: nil, test: nil) }
        #expect(try projection.testRun(in: first.windowID, test: nil).test == "bun test a")
        let run = try projection.testRun(in: "elsewhere", test: "bun test b")
        #expect(run.windowID == second.windowID && run.worktree == "/b" && run.test == "bun test b")
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
