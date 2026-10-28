@testable import CmuxNextPages
import Foundation
import Testing

/// `web-dev.json` (``WebDevOverride``): what it parses to, which builds read it, and how a page
/// request is answered from its server, its overlay or the bundle.
@MainActor
struct WebDevOverrideTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func liveReloadIsOffByDefault() {
        #expect(PageTunables.webDevOverride.defaultValue == false)
    }

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

    /// The overlay's shared chunks (React, `cmux-page://cmux.shared/`) are its pages' `_shared`, through the
    /// symlink an install swaps: the same install as the overlay's pages and viewers.
    @Test func theSharedChunksComeFromTheOverlaysPages() throws {
        let overlay = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overlay) }
        #expect(WebDevOverride(overlay: overlay).sharedOverlayRoot == nil)
        try write("export{}", to: overlay.appending(path: ".gen-1/pages/_shared/react-AB12.js"))
        try FileManager.default.createSymbolicLink(at: overlay.appending(path: "pages"),
                                                   withDestinationURL: overlay.appending(path: ".gen-1/pages"))
        let shared = try #require(WebDevOverride(overlay: overlay).sharedOverlayRoot)
        #expect(shared.path == overlay.appending(path: ".gen-1/pages/_shared").standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: shared.appending(path: "react-AB12.js").path))
        #expect(WebDevOverride().sharedOverlayRoot == nil)
    }

    /// `cmux-page://cmux.shared/` answers from the overlay's `pages/_shared` first: an overlay page imports
    /// the React and chunks its own build wrote, which the bundle does not have. A file the overlay lacks
    /// still comes from the bundle, and without an overlay the overlay's copy is never read.
    @Test func sharedChunksComeFromTheOverlayBeforeTheBundle() async throws {
        let bundled = try temporaryDirectory()
        let overlay = try temporaryDirectory()
        defer { for dir in [bundled, overlay] { try? FileManager.default.removeItem(at: dir) } }
        try write("<p>settings</p>", to: bundled.appending(path: "settings/index.html"))
        try write("bundled react", to: bundled.appending(path: "_shared/react-OLD.js"))
        try write("bundled chunk", to: bundled.appending(path: "_shared/chunk-A.js"))
        try write("overlay react", to: overlay.appending(path: "pages/_shared/react-NEW.js"))
        try write("overlay chunk", to: overlay.appending(path: "pages/_shared/chunk-A.js"))

        let handler = PageSchemeHandler(page: .settings, root: bundled.appending(path: "settings"), devServer: nil,
                                        sharedRoot: bundled.appending(path: "_shared"))
        let origin = PageDescriptor.settings.origin
        func shared(_ name: String) async throws -> String? {
            let url = try #require(URL(string: "cmux-page://cmux.shared/\(name)"))
            return await handler.sharedReply(to: url, origin: origin).map { String(decoding: $0.body, as: UTF8.self) }
        }

        handler.liveOverride = { WebDevOverride(overlay: overlay) }
        let react = try #require(URL(string: "cmux-page://cmux.shared/react-NEW.js"))
        let reply = try #require(await handler.sharedReply(to: react, origin: origin))
        #expect(String(decoding: reply.body, as: UTF8.self) == "overlay react")
        #expect(reply.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == origin)
        #expect(try await shared("chunk-A.js") == "overlay chunk")
        #expect(try await shared("react-OLD.js") == "bundled react")
        // The overlay answers the same origins as the bundle only.
        #expect(await handler.sharedReply(to: react, origin: "https://evil.test") == nil)

        handler.liveOverride = { WebDevOverride() }
        #expect(try await shared("react-NEW.js") == nil)
        #expect(try await shared("chunk-A.js") == "bundled chunk")
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
