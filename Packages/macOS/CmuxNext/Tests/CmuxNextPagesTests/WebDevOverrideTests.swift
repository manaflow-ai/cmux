@testable import CmuxNextPages
import Foundation
import Testing

/// `web-dev.json` (``WebDevOverride``): what it parses to, which builds read it, and how a page
/// request is answered from its server, its overlay or the bundle.
@MainActor
struct WebDevOverrideTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func parsesALoopbackServerAndAHomeOverlay() throws {
        let value = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/", "overlay": "~/web-overlay"}"#.utf8), home: home)
        #expect(value.server?.root.absoluteString == "http://127.0.0.1:4181/")
        #expect(value.overlay?.path == "/Users/someone/web-overlay")
    }

    @Test func dropsAnythingButALoopbackServerAndAnAbsoluteOverlay() {
        let remote = WebDevOverride.parse(Data(#"{"server": "http://10.0.0.2:4181/", "overlay": "relative/dir"}"#.utf8), home: home)
        #expect(remote == WebDevOverride())
        let noPort = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1/"}"#.utf8), home: home)
        #expect(noPort.server == nil)
    }

    @Test func disabledOrInvalidFileIsEmpty() {
        let off = WebDevOverride.parse(Data(#"{"enabled": false, "server": "http://127.0.0.1:4181/"}"#.utf8), home: home)
        #expect(off == WebDevOverride())
        #expect(WebDevOverride.parse(Data("not json".utf8), home: home) == WebDevOverride())
    }

    @Test func onlyDebugAndNightlyBuildsReadTheFile() {
        #expect(WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app", isDebugBuild: true))
        #expect(WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.nightly", isDebugBuild: false))
        #expect(WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.nightly.leo", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.rc", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.nightlyx", isDebugBuild: false))
        // cmux NEXT DEV, a Release compile, reads it; no other id under it does.
        #expect(WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.debug.next", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.debug.nextx", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: "com.cmuxterm.app.debug.next.other", isDebugBuild: false))
        #expect(!WebDevOverride.isAvailable(bundleID: nil, isDebugBuild: false))
    }

    @Test func readsTheOverlayManifestAsTheStamp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let overlay = dir.appending(path: "overlay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data(#"{"stamp":"1"}"#.utf8).write(to: overlay.appending(path: WebDevOverride.manifestName))
        let file = dir.appending(path: WebDevOverride.fileName)
        try Data(#"{"overlay": "\#(overlay.path)"}"#.utf8).write(to: file)

        let value = WebDevOverride.read(file: file, home: home)
        #expect(value.stamp == Data(#"{"stamp":"1"}"#.utf8))
        #expect(WebDevOverride.read(file: dir.appending(path: "missing.json"), home: home) == WebDevOverride())
    }

    @Test func overlayRootNeedsTheEntryAndStaysInside() throws {
        let overlay = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overlay) }
        try write("<p>pane</p>", to: overlay.appending(path: "agent-pane/index.html"))
        let value = WebDevOverride(overlay: overlay)
        #expect(value.overlayRoot("agent-pane")?.lastPathComponent == "agent-pane")
        #expect(value.overlayRoot("webviews-app") == nil)
        #expect(value.overlayRoot("../agent-pane") == nil)
        #expect(WebDevOverride().overlayRoot("agent-pane") == nil)
    }

    @Test func pageFilesComeFromTheOverlay() async throws {
        let bundled = try temporaryDirectory()
        let overlay = try temporaryDirectory()
        defer { for dir in [bundled, overlay] { try? FileManager.default.removeItem(at: dir) } }
        try write("bundled", to: bundled.appending(path: PageDescriptor.markdown.entry))
        try write("overlay", to: overlay.appending(path: "\(bundled.lastPathComponent)/\(PageDescriptor.markdown.entry)"))

        let handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        handler.liveOverride = { WebDevOverride(overlay: overlay) }
        #expect(try await body(handler) == "overlay")
        handler.liveOverride = { WebDevOverride() }
        #expect(try await body(handler) == "bundled")
    }

    @Test func liveServerAnswersAndAStoppedServerFallsBackToTheBundle() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try write("bundled", to: bundled.appending(path: PageDescriptor.markdown.entry))
        let root = try #require(URL(string: "http://127.0.0.1:4181/"))
        let handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        handler.liveOverride = { WebDevOverride(server: PageDevServer(root: root)) }

        handler.fetchDevServer = { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
            return response.map { (Data("served".utf8), $0) }
        }
        #expect(try await body(handler) == "served")

        handler.fetchDevServer = { _ in nil }
        #expect(try await body(handler) == "bundled")

        handler.fetchDevServer = { url in
            HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil).map { (Data("missing".utf8), $0) }
        }
        #expect(try await body(handler) == "bundled")
    }

    private func body(_ handler: PageSchemeHandler) async throws -> String {
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/"))
        let reply = try #require(await handler.reply(to: url))
        return String(decoding: reply.body, as: UTF8.self)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "web-dev-override-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
