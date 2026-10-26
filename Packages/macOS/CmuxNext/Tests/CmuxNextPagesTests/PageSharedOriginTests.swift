@testable import CmuxNextPages
import Foundation
import Testing

/// `cmux-page://cmux.shared/` (``PageSharedChunks``): first-party pages import their shared chunks
/// from one origin, which grants each asking first-party page its own origin and nothing else, and
/// which is never a page.
@MainActor
struct PageSharedOriginTests {
    /// A shared root with a React chunk, a stylesheet, a document and a data file, and a page root
    /// next to it.
    private struct Fixture {
        let base: URL
        let pageRoot: URL
        let shared: URL

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("page-shared-origin-\(UUID().uuidString)", isDirectory: true)
            pageRoot = base.appendingPathComponent("settings", isDirectory: true)
            shared = base.appendingPathComponent("_shared", isDirectory: true)
            try FileManager.default.createDirectory(at: pageRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try Data("<!doctype html><title>Settings</title>".utf8).write(to: pageRoot.appendingPathComponent("index.html"))
            try Data("export const React = 1".utf8).write(to: shared.appendingPathComponent("react-1a2b.js"))
            try Data("body{}".utf8).write(to: shared.appendingPathComponent("ui-3c4d.css"))
            try Data("<!doctype html>".utf8).write(to: shared.appendingPathComponent("index.html"))
            try Data("{}".utf8).write(to: shared.appendingPathComponent("data.json"))
        }

        func handler(_ page: PageDescriptor = .settings) -> PageSchemeHandler {
            PageSchemeHandler(page: page, root: pageRoot, devServer: nil, sharedRoot: shared)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private static func react() throws -> URL { try #require(URL(string: "cmux-page://cmux.shared/react-1a2b.js")) }

    @Test func aFirstPartyPageGetsTheChunkWithItsOwnOrigin() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let react = try Self.react()
        let origin = PageDescriptor.settings.origin
        let reply = try #require(await fixture.handler().sharedReply(to: react, origin: origin))
        let headers = reply.response
        #expect(headers.statusCode == 200)
        #expect(reply.body == Data("export const React = 1".utf8))
        #expect(headers.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == origin)
        #expect(headers.value(forHTTPHeaderField: "Vary") == "Origin")
        #expect(headers.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(headers.value(forHTTPHeaderField: "Content-Security-Policy") == PageID.sharedChunkPolicy)
        #expect(headers.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")

        let style = try #require(URL(string: "cmux-page://cmux.shared/ui-3c4d.css"))
        let css = try #require(await fixture.handler().sharedReply(to: style, origin: origin))
        #expect(css.response.value(forHTTPHeaderField: "Content-Type") == "text/css")
    }

    @Test func noOtherOriginGetsAnAnswerOrAnAccessControlHeader() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let react = try Self.react()
        let refused: [String?] = [
            nil, "", "null", "https://evil.test", "http://127.0.0.1:8080", "cmux-page://com.example.notes",
            "cmux-page://mycmux.settings", "cmux-page://cmux.shared", "cmux-page://CMUX.settings",
            "cmux-page://cmux.settings:8080", "cmux-page://cmux.settings/", "cmux-page://", "cmux-page://cmux..settings",
            "file://", "cmux-agent://pane",
        ]
        for origin in refused {
            #expect(PageSharedChunks.allowedOrigin(origin) == nil, "\(origin ?? "no Origin") may read cmux.shared")
            #expect(await fixture.handler().sharedReply(to: react, origin: origin) == nil,
                    "\(origin ?? "no Origin") got an answer")
        }
        for page in [PageDescriptor.settings, .history, .markdown, .changelog] {
            #expect(PageSharedChunks.allowedOrigin(page.origin) == page.origin, "\(page.id) may not read cmux.shared")
        }
    }

    @Test func navigatingToTheSharedOriginIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let react = try Self.react()
        // A top document at cmux.shared, even with a first-party Origin header.
        #expect(await fixture.handler().sharedReply(to: react, origin: PageDescriptor.settings.origin,
                                                    mainDocument: react) == nil)
        let root = try #require(URL(string: "cmux-page://cmux.shared/"))
        #expect(await fixture.handler().sharedReply(to: root, origin: PageDescriptor.settings.origin) == nil)
        // No page has the shared origin, and no app can claim it.
        #expect(PageID.isReserved(PageID.sharedHost))
        #expect(!PageID.isFirstParty(PageID.sharedHost))
        #expect(throws: PageID.Refusal.reservedID(PageID.sharedHost)) {
            try PageDescriptor.appPage(id: PageID.sharedHost, resource: "x", namespaces: [])
        }
    }

    @Test func onlyScriptAndStyleInsideTheRootAreServed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let react = try Self.react()
        let outside = fixture.base.appendingPathComponent("outside.js")
        try Data("export const secret = 1".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.shared.appendingPathComponent("escape.js"),
                                                   withDestinationURL: outside)
        let origin = PageDescriptor.settings.origin
        for path in ["/index.html", "/data.json", "/", "/missing.js", "/escape.js", "/../settings/index.html",
                     "/%2e%2e/outside.js", "/react-1a2b.JS"] {
            let url = try #require(URL(string: "cmux-page://cmux.shared" + path))
            #expect(await fixture.handler().sharedReply(to: url, origin: origin) == nil, "cmux.shared served \(path)")
        }
        // A page's own handler never serves the shared origin as a page file, nor a page file as a chunk.
        #expect(PageSchemeHandler.route(for: react, page: .settings, root: fixture.pageRoot) == nil)
        let pageFile = try #require(URL(string: "cmux-page://cmux.settings/index.html"))
        #expect(PageSharedChunks.allowedOrigin(for: pageFile, origin: PageDescriptor.settings.origin, mainDocument: nil) == nil)
    }

    /// A page from a web-dev.json overlay (web-overlay.sh install) imports the chunks of its own build,
    /// which only the overlay's `pages/_shared` holds: the shared origin serves them from there, as the
    /// page's own files come from the overlay. A chunk only the bundle holds still comes from the bundle,
    /// and an overlay file never escapes its folder.
    @Test func anOverlayPageGetsTheChunksOfItsOwnBuild() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overlay = fixture.base.appendingPathComponent("overlay", isDirectory: true)
        let overlayShared = overlay.appendingPathComponent(PageSharedChunks.overlayFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: overlayShared, withIntermediateDirectories: true)
        try Data("export const pane = 2".utf8).write(to: overlayShared.appendingPathComponent("pane-9z8y.js"))
        try FileManager.default.createSymbolicLink(at: overlayShared.appendingPathComponent("escape.js"),
                                                   withDestinationURL: fixture.pageRoot.appendingPathComponent("index.html"))
        let origin = PageDescriptor.settings.origin
        let paneChunk = try #require(URL(string: "cmux-page://cmux.shared/pane-9z8y.js"))
        let escape = try #require(URL(string: "cmux-page://cmux.shared/escape.js"))
        let handler = fixture.handler()

        handler.liveOverride = { WebDevOverride() }
        #expect(await handler.sharedReply(to: paneChunk, origin: origin) == nil)

        handler.liveOverride = { WebDevOverride(overlay: overlay) }
        let reply = try #require(await handler.sharedReply(to: paneChunk, origin: origin))
        #expect(reply.body == Data("export const pane = 2".utf8))
        #expect(reply.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == origin)
        let reactURL = try Self.react()
        let react = try #require(await handler.sharedReply(to: reactURL, origin: origin))
        #expect(react.body == Data("export const React = 1".utf8))
        #expect(await handler.sharedReply(to: escape, origin: origin) == nil)
    }

    /// A Debug page root override (`CMUX_NEXT_PAGE_ROOT_cmux_agent`, agent-stream-e2e.py's variants) loads
    /// a page of another build; `CMUX_NEXT_PAGE_ROOT_cmux_shared` names that build's shared folder, read
    /// before the bundled one.
    @Test func theDebugSharedRootServesAVariantBuildsChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let variant = fixture.base.appendingPathComponent("variant-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        try Data("export const variant = 3".utf8).write(to: variant.appendingPathComponent("pane-7x6w.js"))
        let handler = PageSchemeHandler(page: .settings, root: fixture.pageRoot, devServer: nil, sharedRoot: fixture.shared,
                                        debugSharedRoot: variant)
        handler.liveOverride = { WebDevOverride() }
        let origin = PageDescriptor.settings.origin
        let chunk = try #require(URL(string: "cmux-page://cmux.shared/pane-7x6w.js"))
        let variantReply = try #require(await handler.sharedReply(to: chunk, origin: origin))
        #expect(variantReply.body == Data("export const variant = 3".utf8))
        let reactURL = try Self.react()
        let bundledReply = try #require(await handler.sharedReply(to: reactURL, origin: origin))
        #expect(bundledReply.body == Data("export const React = 1".utf8))
        #expect(PageSharedChunks.roots(overlay: nil, debug: variant, update: fixture.shared, bundled: fixture.shared)
                == [variant, fixture.shared])
    }

    /// One React URL: every page asks for the same `cmux-page://cmux.shared/...` URL and gets the
    /// same bytes, each readable by that page only, and every shipped page's policy names that one
    /// origin for script and style. An app page's never does.
    @Test func everyShippedPageLoadsTheSameChunkURL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let react = try Self.react()
        var bodies: Set<Data> = []
        for page in [PageDescriptor.settings, .history, .cloud, .markdown] {
            let reply = try #require(await fixture.handler(page).sharedReply(to: react, origin: page.origin))
            bodies.insert(reply.body)
            #expect(reply.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == page.origin)
        }
        #expect(bodies.count == 1)

        for page in [PageDescriptor.settings, .history, .cloud, .markdown, .diff, .editor, .changelog] {
            let header = page.csp.header
            #expect(header.contains("script-src 'self'"), "\(page.id): \(header)")
            for directive in ["script-src", "style-src"] {
                let sources = try #require(Self.sources(of: directive, in: header))
                #expect(sources.contains(PageID.sharedOrigin), "\(page.id) \(directive): \(header)")
            }
        }
        let app = try PageDescriptor.appPage(id: "com.example.notes", resource: "notes", namespaces: [])
        #expect(!app.csp.header.contains(PageID.sharedHost))
        #expect(!PageCSP.strict.header.contains(PageID.sharedHost))
    }

    /// A built page (build-pages.mjs) names its shared chunks by the shared origin, never by a path
    /// relative to its own folder: `../_shared/react.js` would resolve inside each page's origin, a
    /// different URL per page. No page folder holds a `_shared` copy, and every shared-origin URL a
    /// page names is a file of the bundled shared root. Vacuous when no pages are built (the bundle
    /// holds only GENERATED.md); the webviews test `pages-split-build.test.ts` builds fixture pages.
    @Test func builtPagesNameSharedChunksByTheSharedOrigin() throws {
        guard let pages = PageDescriptor.settings.pagesBundleRoot?.deletingLastPathComponent() else { return }
        let sharedRoot = pages.appendingPathComponent("_shared", isDirectory: true)
        let files = FileManager.default.enumerator(at: pages, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        let prefix = PageID.sharedOrigin + "/"
        for file in files where ["html", "js"].contains(file.pathExtension) {
            guard !file.standardizedFileURL.pathComponents.contains("_shared") else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("../_shared/"), "\(file.lastPathComponent) names a shared chunk by a relative path")
            for url in Self.sharedURLs(in: text, prefix: prefix) {
                let chunk = try #require(URL(string: url))
                #expect(PageSharedChunks.file(for: chunk, root: sharedRoot) != nil,
                        "\(file.lastPathComponent) names \(url), which cmux.shared does not serve")
            }
        }
        let pageFolders = try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
        for folder in pageFolders where folder.lastPathComponent != "_shared" {
            let copy = folder.appendingPathComponent("_shared", isDirectory: true)
            #expect(!FileManager.default.fileExists(atPath: copy.path), "\(folder.lastPathComponent) has its own _shared copy")
        }
    }

    /// Every `cmux-page://cmux.shared/<name>.js` URL in `text`, as a JavaScript string or an attribute.
    private static func sharedURLs(in text: String, prefix: String) -> [String] {
        text.components(separatedBy: prefix).dropFirst().compactMap { rest -> String? in
            let name = rest.prefix(while: { $0 != "\"" && $0 != "'" })
            return name.hasSuffix(".js") ? prefix + String(name) : nil
        }
    }

    private static func sources(of directive: String, in header: String) -> [String]? {
        header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(directive + " ") }?
            .split(separator: " ").dropFirst().map(String.init)
    }
}
