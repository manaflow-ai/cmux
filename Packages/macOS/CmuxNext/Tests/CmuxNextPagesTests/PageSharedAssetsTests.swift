import Foundation
import CmuxNextCompat
@testable import CmuxNextPages
import Testing

/// Production pages share code on disk, while keeping their own origins and private roots.
struct PageSharedAssetsTests {
    @Test func sharedCodeFollowsThePinnedUpdateRoot() async throws {
        let bundled = URL(fileURLWithPath: "/App.app/Resources/pages", isDirectory: true)
        let overlay = WebBundleOverlay(bases: [.init(bundled: bundled.path, output: WebBundleOverlay.pagesOutput)])
        let first = URL(fileURLWithPath: "/updates/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/updates/second", isDirectory: true)
        #expect(overlay.activate(first))
        let pageRoot = bundled.appendingPathComponent("settings", isDirectory: true)
        let pinned = await overlay.root(for: pageRoot)
        #expect(overlay.activate(second))
        let current = await overlay.root(for: pageRoot)
        let url = try #require(URL(string: "cmux-page://cmux.settings/__shared/runtime.js"))
        #expect(PageSchemeHandler.fileURL(for: url, page: .settings, root: pinned)?.path
            == first.appendingPathComponent(WebBundleOverlay.pagesOutput + "/__shared/runtime.js").path)
        #expect(PageSchemeHandler.fileURL(for: url, page: .settings, root: current)?.path
            == second.appendingPathComponent(WebBundleOverlay.pagesOutput + "/__shared/runtime.js").path)
    }

    @Test func sharedCodeStaysInThePagesTreeAndKeepsThePagesOrigin() throws {
        let pages = URL(fileURLWithPath: "/fixture/pages", isDirectory: true)
        let root = pages.appendingPathComponent("settings", isDirectory: true)
        let shared = try #require(URL(string: "cmux-page://cmux.settings/__shared/runtime.js"))
        #expect(PageSchemeHandler.fileURL(for: shared, page: .settings, root: root)
            == pages.appendingPathComponent("__shared/runtime.js"))
        let own = try #require(URL(string: "cmux-page://cmux.settings/app.js"))
        #expect(PageSchemeHandler.fileURL(for: own, page: .settings, root: root)
            == root.appendingPathComponent("app.js"))
        for address in ["cmux-page://cmux.history/__shared/runtime.js",
                        "cmux-page://cmux.settings/__shared/../history/index.html",
                        "cmux-page://cmux.settings/__shared/nested/runtime.js",
                        "cmux-page://cmux.settings/__shared/private.json"] {
            let url = try #require(URL(string: address))
            #expect(PageSchemeHandler.fileURL(for: url, page: .settings, root: root) == nil)
        }
        let thirdParty = PageDescriptor(id: "org.example.page", resource: "settings", namespaces: [])
        let foreign = try #require(URL(string: "cmux-page://org.example.page/__shared/runtime.js"))
        // A third-party root never acquires access to its sibling directory.
        #expect(PageSchemeHandler.fileURL(for: foreign, page: thirdParty, root: root)
            == root.appendingPathComponent("__shared/runtime.js"))
    }

    @Test func everyShippedPageUsesThePagesSharedDirectory() throws {
        // GitHub is shipped by build-pages-web.sh but is intentionally absent from the
        // daemon's first-party WebSocket trust table. Shared assets must still resolve from
        // the sibling pages/__shared directory without granting it daemon access.
        let pages = URL(fileURLWithPath: "/fixture/pages", isDirectory: true)
        let root = pages.appendingPathComponent("github", isDirectory: true)
        let url = try #require(URL(string: "cmux-page://cmux.github/__shared/runtime.js"))
        #expect(PageSchemeHandler.fileURL(for: url, page: .github, root: root)?.path
            == pages.appendingPathComponent("__shared/runtime.js").path)
        #expect(!PageID.isFirstParty("cmux.github"))
        #expect(FirstPartyPages.shippedIDs.contains("cmux.github"))
    }

    @Test @MainActor func readsSharedCodeAndRefusesSymlinkEscapes() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pages = temp.appendingPathComponent("pages", isDirectory: true)
        let root = pages.appendingPathComponent("settings", isDirectory: true)
        let shared = pages.appendingPathComponent("__shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let file = shared.appendingPathComponent("runtime.js")
        try Data("export const loaded = true;".utf8).write(to: file)
        let url = try #require(URL(string: "cmux-page://cmux.settings/__shared/runtime.js"))
        let handler = PageSchemeHandler(page: .settings, root: root, devServer: nil)
        handler.liveOverride = { .init(server: nil, overlay: nil) }
        let reply = try #require(await handler.reply(to: url))
        #expect(reply.body == Data("export const loaded = true;".utf8))
        #expect(reply.response.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageDescriptor.settings.csp.header)
        // Chromium's shim serves the bundled document outside the live loop. Its shared files
        // use that exact root too, rather than selecting a currently active web update.
        let chromium = await PageWebView.liveChromiumResource(url, range: nil, page: .settings, root: root, bundledOnly: true)
        #expect(chromium.body == reply.body)
        #expect(chromium.mimeType == "text/javascript")
        #expect(chromium.csp == PageDescriptor.settings.csp.header)
        let outside = temp.appendingPathComponent("private.js")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("escape.js"), withDestinationURL: outside)
        let escape = try #require(URL(string: "cmux-page://cmux.settings/__shared/escape.js"))
        #expect(PageSchemeHandler.fileURL(for: escape, page: .settings, root: root) == nil)
        #expect(await PageWebView.liveChromiumResource(escape, range: nil, page: .settings, root: root, bundledOnly: true).status == 404)
        // A symlink for the shared directory itself must not expand the mount.
        try FileManager.default.removeItem(at: shared)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: temp)
        let directoryEscape = try #require(URL(string: "cmux-page://cmux.settings/__shared/private.js"))
        #expect(PageSchemeHandler.fileURL(for: directoryEscape, page: .settings, root: root) == nil)
    }
}
