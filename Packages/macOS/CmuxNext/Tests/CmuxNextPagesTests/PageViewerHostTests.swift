import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// The diff and markdown host pieces (plans/cmux-next/diff-host.md S1): the dynamic-resource
/// hook of the scheme handler, the surface a page paints, and the per-page commands.
@MainActor
@Suite struct PageViewerHostTests {
    final class Source: PageDynamicResourceSource {
        var requests: [PageResourceRequest] = []
        var answer: PageResource?

        func resource(for request: PageResourceRequest) async -> PageResource? {
            requests.append(request)
            return answer
        }
    }

    /// A page root with `index.html` and a file under the dynamic prefix the handler must never serve.
    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-pages-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "__patch"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appending(path: "index.html"))
        try Data("static".utf8).write(to: root.appending(path: "__patch/a.patch"))
        return root
    }

    static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/invalid")
    }

    func header(_ reply: PageSchemeHandler.Reply?, _ name: String) -> String? {
        reply?.response.value(forHTTPHeaderField: name)
    }

    @Test func aDynamicPrefixGoesToTheSourceWithItsCheckedPath() async throws {
        let root = try makeRoot()
        let source = Source()
        source.answer = PageResource(data: Data("diff --git".utf8), mimeType: "text/x-diff; charset=utf-8")
        let handler = PageSchemeHandler(page: .diff, root: root, dynamicSource: source)
        let url = Self.url("cmux-page://cmux.diff/__patch/tok123/src/a.swift.patch?x=1")
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.response.statusCode == 200)
        #expect(reply.body == Data("diff --git".utf8))
        #expect(header(reply, "Content-Type") == "text/x-diff; charset=utf-8")
        #expect(source.requests == [PageResourceRequest(prefix: "__patch", path: ["tok123", "src", "a.swift.patch"], url: url)])
    }

    @Test func aMissingDynamicResourceIsA404WithThePageHeadersNeverAStaticFile() async throws {
        let root = try makeRoot()
        let source = Source()
        let handler = PageSchemeHandler(page: .diff, root: root, dynamicSource: source)
        let reply = try #require(await handler.reply(to: Self.url("cmux-page://cmux.diff/__patch/a.patch")))
        #expect(reply.response.statusCode == 404)
        #expect(reply.body.isEmpty)
        #expect(header(reply, "X-Content-Type-Options") == "nosniff")
        #expect(header(reply, "Content-Security-Policy")?.hasPrefix("default-src 'none'") == true)
        #expect(header(reply, "Cache-Control") == "no-store")
        // No source at all: still a 404, the file under the prefix stays unserved.
        let bare = PageSchemeHandler(page: .diff, root: root)
        #expect(await bare.reply(to: Self.url("cmux-page://cmux.diff/__patch/a.patch"))?.response.statusCode == 404)
    }

    @Test func theDynamicPathKeepsTheStaticContainmentRules() async throws {
        let root = try makeRoot()
        let source = Source()
        source.answer = PageResource(data: Data("x".utf8))
        let handler = PageSchemeHandler(page: .diff, root: root, dynamicSource: source)
        for raw in [
            "cmux-page://cmux.diff/__patch/../index.html", "cmux-page://cmux.diff/__patch/%2e%2e/index.html",
            "cmux-page://cmux.diff/__patch/./a", "cmux-page://cmux.history/__patch/a", "cmux-page2://cmux.diff/__patch/a",
        ] {
            #expect(await handler.reply(to: Self.url(raw))?.response.statusCode != 200, "\(raw) answered")
        }
        #expect(source.requests.isEmpty)
        // Only the whole first component is a prefix; a page without the prefix serves its files.
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(PageSchemeHandler.fileURL(for: Self.url("cmux-page://cmux.diff/__patchx/a"), page: .diff, root: root)?.path
            == base + "/__patchx/a")
        #expect(PageSchemeHandler.fileURL(for: Self.url("cmux-page://cmux.diff/__patch/a.patch"), page: .diff, root: root) == nil)
        #expect(PageSchemeHandler.fileURL(for: Self.url("cmux-page://cmux.history/__patch/a.patch"), page: .history, root: root)?.path
            == base + "/__patch/a.patch")
    }

    @Test func aDynamicMIMETypeFollowsTheStaticRuleWhenMissingOrMalformed() async throws {
        let root = try makeRoot()
        let source = Source()
        let handler = PageSchemeHandler(page: .diff, root: root, dynamicSource: source)
        let url = Self.url("cmux-page://cmux.diff/__patch/t/data.json")
        source.answer = PageResource(data: Data("{}".utf8))
        #expect(header(await handler.reply(to: url), "Content-Type") == "application/json")
        source.answer = PageResource(data: Data("{}".utf8), mimeType: "text/html\r\nSet-Cookie: a=b")
        #expect(header(await handler.reply(to: url), "Content-Type") == "application/json")
        source.answer = PageResource(data: Data("{}".utf8), mimeType: "")
        let noExtension = Self.url("cmux-page://cmux.diff/__patch/t/blob")
        #expect(header(await handler.reply(to: noExtension), "Content-Type") == "application/octet-stream")
    }

    @Test func aStaticFileCarriesNosniffAndThePageCSP() async throws {
        let root = try makeRoot()
        let handler = PageSchemeHandler(page: .history, root: root)
        let reply = try #require(await handler.reply(to: Self.url("cmux-page://cmux.history/")))
        #expect(reply.response.statusCode == 200)
        #expect(header(reply, "Content-Type") == "text/html")
        #expect(header(reply, "X-Content-Type-Options") == "nosniff")
        #expect(header(reply, "Content-Security-Policy") == PageSchemeHandler.contentSecurityPolicy)
        #expect(await handler.reply(to: Self.url("cmux-page://cmux.history/missing.js")) == nil)
    }

    /// The diff page is the webviews-app build's entry, and as a first-party page it is never
    /// served from an arbitrary root (only its approved root or the DEBUG override).
    @Test func theDiffPageServesItsEntryOnlyFromAnApprovedRoot() throws {
        let root = try makeRoot()
        #expect(PageDescriptor.diff.resource == "webviews-app" && PageDescriptor.diff.entry == "diff-page.html")
        #expect(PageSchemeHandler.fileURL(for: Self.url("cmux-page://cmux.diff/"), page: .diff, root: root)?.lastPathComponent
            == "diff-page.html")
        #expect(!PageWebView.mayServe(.diff, from: root))
        #expect(!PageWebView.mayServe(.markdown, from: root))
    }

    /// S4's launch call registers the app bundle's webviews-app directory, and the diff page is
    /// then served from it with no DEBUG override; a later registration cannot move it.
    @Test func theDiffPageIsServedFromTheRegisteredAppRoot() async throws {
        #expect(PageWebView.debugRoot(for: .diff) == nil)
        let resources = FileManager.default.temporaryDirectory.appending(path: "cmux-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = PageDescriptor.diffRoot(inAppResources: resources)
        #expect(root.path.hasSuffix("/markdown-viewer/webviews-app"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>diff</html>".utf8).write(to: root.appending(path: PageDescriptor.diff.entry))
        #expect(!PageWebView.mayServe(.diff, from: root))
        #expect(PageDescriptor.registerDiffRoot(appResources: resources) == root)
        #expect(PageWebView.mayServe(.diff, from: root))
        #expect(PageWebView.servedRoot(for: .diff) == root)
        PageDescriptor.registerDiffRoot(appResources: FileManager.default.temporaryDirectory.appending(path: "cmux-other"))
        #expect(PageWebView.servedRoot(for: .diff) == root)
        let handler = PageSchemeHandler(page: .diff, root: root)
        let reply = try #require(await handler.reply(to: Self.url("cmux-page://cmux.diff/")))
        #expect(reply.body == Data("<html>diff</html>".utf8))
        #expect(header(reply, "Content-Security-Policy") == PageDescriptor.diff.csp.header)
    }

    /// `appearance.surfaces.diff` reaches the page background only for a page that is that surface.
    @Test func thePageSurfaceSelectsItsBackgroundOverride() throws {
        let root = try makeRoot()
        let app = try PageDescriptor.appPage(id: "com.acme.viewer", resource: "viewer", namespaces: [])
        let page = try #require(PageWebView(descriptor: app, root: root, routes: [], surface: .diff))
        defer { page.close() }
        #expect(page.themeSurface == .diff)
        let red = ThemeRGB(red: 0.8, green: 0.2, blue: 0.2)
        let backgrounds = SurfaceBackgrounds(overrides: [.diff: SurfaceBackground(color: red, opacity: 1)])
        #expect(page.currentTheme(backgrounds: backgrounds).variables["--cmux-surface-background"] == "rgba(204, 51, 51, 1.0)")
        page.themeSurface = nil
        #expect(page.currentTheme(backgrounds: backgrounds) == WebTheme(page.themeTokens,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency))
        let plain = try #require(PageWebView(descriptor: app, root: root, routes: []))
        defer { plain.close() }
        #expect(plain.themeSurface == nil)
    }

    @Test func eachViewerTakesItsOwnCommandsAndTheSharedOnes() {
        #expect(PageDescriptor.diff.commands == PageNativeOp.commands.union(DiffPageCommand.all))
        #expect(PageDescriptor.markdown.commands == PageNativeOp.commands.union(MarkdownPageCommand.all))
        #expect(PageDescriptor.history.commands == PageNativeOp.commands)
        #expect(!PageDescriptor.markdown.commands.contains(DiffPageCommand.nextHunk))
        // Every diffViewer* action sends a command the diff page takes.
        #expect(DiffPageCommand.forAction.count == 11)
        #expect(Set(DiffPageCommand.forAction.values).isSubset(of: PageDescriptor.diff.commands))
        #expect(Set(MarkdownPageCommand.forAction.values).isSubset(of: PageDescriptor.markdown.commands))
    }

    @Test func aDiffCommandReachesOnlyTheDiffPage() async {
        let diff = PageRouter(descriptor: .diff, routes: [])
        let history = PageRouter(descriptor: .history, routes: [])
        let sent = PageRouterTests.Box()
        diff.send = { sent.items.append($0) }
        _ = await diff.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        _ = await history.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageCommand)])
        #expect(diff.publishCommand(DiffPageCommand.toggleViewed))
        #expect(!history.publishCommand(DiffPageCommand.toggleViewed))
        #expect(sent.items.last?["data"]?["command"]?.stringValue == "toggleViewed")
    }
}
