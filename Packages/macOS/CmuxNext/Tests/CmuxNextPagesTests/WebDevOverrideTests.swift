@testable import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// `web-dev.json` (``WebDevOverride``): what it parses to, that every build reads it unless Live Web
/// Reload is off, and how a page request is answered from its server, its overlay or the bundle,
/// in WebKit and in Chromium.
@MainActor
struct WebDevOverrideTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    /// Leo, 2026-11-05: "we probably want to have this feature like toggleable on by default".
    @Test func liveReloadIsOnByDefaultInEveryBuild() {
        #expect(UpdatesSettings.liveWebReloadDefault)
        #expect(UpdatesSettings().liveWebReload)
        #expect(WebDevOverride.isEnabled)
    }

    @Test func theSettingTurnsItOffAndOnAgain() {
        var diagnostics: [SettingsDiagnostic] = []
        let off = UpdatesSettings.parse(.object(["updates": .object(["liveWebReload": .bool(false)])]), diagnostics: &diagnostics)
        #expect(!off.liveWebReload)
        #expect(UpdatesSettings.parse(.object([:]), diagnostics: &diagnostics).liveWebReload)
        #expect(diagnostics.isEmpty)
    }

    @Test func parsesALoopbackServerAndAHomeOverlay() throws {
        let value = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/", "token": "0123456789abcdef0123456789abcdef01234567", "overlay": "~/web-overlay"}"#.utf8), home: home)
        #expect(value.server?.root.absoluteString == "http://127.0.0.1:4181/")
        #expect(value.server?.token == "0123456789abcdef0123456789abcdef01234567")
        #expect(value.overlay?.path == "/Users/someone/web-overlay")
    }

    /// Every build reads the file, so a server is trusted only with its token: a stale file's port
    /// may be held by any local process.
    @Test func aServerWithoutAValidTokenIsIgnored() {
        let none = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/"}"#.utf8), home: home)
        #expect(none.server == nil)
        let short = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/", "token": "abc"}"#.utf8), home: home)
        #expect(short.server == nil)
        let header = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/", "token": "0123456789abcdef0123456789abcdef01234567\r\nX: y"}"#.utf8), home: home)
        #expect(header.server == nil)
    }

    @Test func dropsAnythingButALoopbackServerAndAnAbsoluteOverlay() {
        let remote = WebDevOverride.parse(Data(#"{"server": "http://10.0.0.2:4181/", "overlay": "relative/dir"}"#.utf8), home: home)
        #expect(remote == WebDevOverride())
        let noPort = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1/", "token": "0123456789abcdef0123456789abcdef01234567"}"#.utf8), home: home)
        #expect(noPort.server == nil)
    }

    @Test func parsesALoopbackGalleryServerThatPagesIgnore() {
        let value = WebDevOverride.parse(Data(#"{"gallery": "http://127.0.0.1:4178/"}"#.utf8), home: home)
        #expect(value.gallery?.absoluteString == "http://127.0.0.1:4178/")
        #expect(!value.isActive)
        let remote = WebDevOverride.parse(Data(#"{"gallery": "http://10.0.0.2:4178/"}"#.utf8), home: home)
        #expect(remote.gallery == nil)
    }

    @Test func disabledOrInvalidFileIsEmpty() {
        let off = WebDevOverride.parse(Data(#"{"enabled": false, "server": "http://127.0.0.1:4181/"}"#.utf8), home: home)
        #expect(off == WebDevOverride())
        #expect(WebDevOverride.parse(Data("not json".utf8), home: home) == WebDevOverride())
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
        handler.liveOverride = { WebDevOverride(server: PageDevServer(root: root, token: "0123456789abcdef0123456789abcdef01234567")) }

        handler.fetchDevServer = { request in Self.proven(request, token: "0123456789abcdef0123456789abcdef01234567", body: "served") }
        #expect(try await body(handler) == "served")

        // Another process on the port: no proof, the token itself, a proof for another nonce or
        // with another token serves nothing.
        let forged: [@Sendable (URLRequest) -> [String: String]] = [
            { _ in [:] },
            { _ in [PageDevServer.proofHeader: "0123456789abcdef0123456789abcdef01234567"] },
            { _ in [PageDevServer.proofHeader: PageDevServer.proof(token: "0123456789abcdef0123456789abcdef01234567", nonce: "recorded")] },
            { request in [PageDevServer.proofHeader: PageDevServer.proof(token: String(repeating: "f", count: 40),
                                                                         nonce: request.value(forHTTPHeaderField: PageDevServer.nonceHeader) ?? "")] },
        ]
        for headers in forged {
            handler.fetchDevServer = { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: headers(request).merging(["Content-Type": "text/html"]) { a, _ in a })
                    .map { (Data("intruder".utf8), $0) }
            }
            #expect(try await body(handler) == "bundled")
        }

        handler.fetchDevServer = { _ in nil }
        #expect(try await body(handler) == "bundled")

        handler.fetchDevServer = { request in Self.proven(request, token: "0123456789abcdef0123456789abcdef01234567", body: "missing", status: 404) }
        #expect(try await body(handler) == "bundled")
    }

    /// A Chromium page's file while live comes the same way, with the dev server's policy, so the
    /// page's HMR socket may connect.
    @Test func chromiumGetsTheServersFileAndItsPolicy() async throws {
        let bundled = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundled) }
        try write("bundled", to: bundled.appending(path: PageDescriptor.markdown.entry))
        let root = try #require(URL(string: "http://127.0.0.1:4181/"))
        let server = PageDevServer(root: root, token: "0123456789abcdef0123456789abcdef01234567")
        let handler = PageSchemeHandler(page: .markdown, root: bundled, devServer: nil)
        handler.liveOverride = { WebDevOverride(server: server) }
        handler.fetchDevServer = { request in Self.proven(request, token: "0123456789abcdef0123456789abcdef01234567", body: "served") }
        let url = try #require(URL(string: PageDescriptor.markdown.origin + "/"))
        let reply = try #require(await handler.reply(to: url))
        let answer = PageSchemeHandler.chromiumResponse(reply)
        #expect(answer.status == 200)
        #expect(answer.mimeType == "text/html")
        #expect(String(decoding: answer.body, as: UTF8.self) == "served")
        #expect(answer.csp == server.csp(for: .markdown).header)
        #expect(answer.csp?.contains("ws://127.0.0.1:4181") == true)
    }

    /// The agent chat's page host loads from the server's agent pane entry, and its policy drops
    /// `'none'` (which may not share a source list) for the server's socket.
    @Test func theAgentPageLoadsFromTheServersAgentPane() throws {
        let server = PageDevServer(root: try #require(URL(string: "http://127.0.0.1:4200/")))
        let document = try #require(URL(string: "cmux-page://cmux.agent/"))
        #expect(server.url(for: document, page: .agentPageForTests)?.absoluteString == "http://127.0.0.1:4200/agent-pane/")
        let script = try #require(URL(string: "cmux-page://cmux.agent/src/main.tsx?t=1"))
        #expect(server.url(for: script, page: .agentPageForTests)?.absoluteString == "http://127.0.0.1:4200/src/main.tsx?t=1")
        let connect = server.csp(for: .agentPageForTests).connect
        #expect(!connect.contains("'none'"))
        #expect(connect.contains("ws://127.0.0.1:4200"))
    }

    /// The real server's answer to `request`: the proof of `token` for the request's nonce, which
    /// the request carries while the token itself does not.
    private static func proven(_ request: URLRequest, token: String, body: String, status: Int = 200) -> (Data, HTTPURLResponse)? {
        guard let url = request.url, let nonce = request.value(forHTTPHeaderField: PageDevServer.nonceHeader),
              nonce.count == 64, !(request.allHTTPHeaderFields ?? [:]).values.contains(token) else { return nil }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                               headerFields: ["Content-Type": "text/html", PageDevServer.proofHeader: PageDevServer.proof(token: token, nonce: nonce)])
            .map { (Data(body.utf8), $0) }
    }

    /// A known HMAC-SHA256 answer, so the app and `webviews/dev-server/plugins.ts` agree.
    @Test func theProofIsHMACSHA256OfTheNonce() {
        #expect(PageDevServer.proof(token: "key", nonce: "The quick brown fox jumps over the lazy dog")
            == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
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

private extension PageDescriptor {
    /// The agent chat's page host as CmuxNextAgentPane declares it (`PageDescriptor.agent`): its id,
    /// folder and a policy that opens no connection.
    static let agentPageForTests = PageDescriptor(id: "cmux.agent", resource: "agent-pane", namespaces: [],
                                                  csp: PageCSP(connect: ["'none'"], inlineScript: false))
}
