@testable import CmuxNextPages
import Foundation
import Testing

/// ``PageDevServer/pageIDs`` against the pages the webviews dev server builds.
struct PageDevServerTests {
    /// The dev server's entries: every `webviews/src/pages/<resource>/main.tsx`. The test reads only
    /// these files, and names them by this pattern so `scripts/cmux-next/ci-target-graph.py` records
    /// the pattern, not the whole pages folder, as what this target reads: an edit inside a page
    /// leaves the list as it was, and a page added or removed runs the test.
    static let entries = "webviews/src/pages/*/main.tsx"

    /// Every `webviews/src/pages/<resource>/` with a `main.tsx` (the dev server's entries) is a
    /// page the server serves, as `cmux.<resource>`, or one it never serves (``PageDevServer/bundledOnlyPageIDs``),
    /// and the lists name no other page: a new page would otherwise keep its bundled files under `web-dev.json`.
    @Test func servesExactlyTheWebviewsPages() throws {
        let parts = Self.entries.components(separatedBy: "/*/")
        try #require(parts.count == 2, "\(Self.entries) is not <folder>/*/<entry>")
        let pages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(parts[0])
        let resources = try FileManager.default.contentsOfDirectory(atPath: pages.path)
            .filter { FileManager.default.fileExists(atPath: pages.appendingPathComponent("\($0)/\(parts[1])").path) }
        #expect(!resources.isEmpty, "no pages under \(pages.path)")
        #expect(Set(resources.map { "cmux.\($0)" }) == PageDevServer.pageIDs.union(PageDevServer.bundledOnlyPageIDs))
        #expect(PageDevServer.pageIDs.isDisjoint(with: PageDevServer.bundledOnlyPageIDs))
    }

    /// SECURITY (cmux#37286): a bundled-only page takes no DEBUG root override
    /// (`CMUX_NEXT_PAGE_ROOT_<id>`), so it is served only from the app's bundle; another first-party page still does.
    @Test func aBundledOnlyPageTakesNoDebugRootOverride() {
        for id in PageDevServer.bundledOnlyPageIDs {
            let page = PageDescriptor(id: id, resource: String(id.dropFirst("cmux.".count)), namespaces: [])
            let environment = ["CMUX_NEXT_PAGE_ROOT_" + id.replacingOccurrences(of: ".", with: "_"): "/tmp/forged-page"]
            #expect(PageWebView.debugRoot(for: page, environment: environment) == nil, "\(id)")
            #expect(!PageWebView.mayServe(page, from: URL(fileURLWithPath: "/tmp/forged-page", isDirectory: true)), "\(id)")
        }
        #if DEBUG
        let history = PageDescriptor(id: "cmux.history", resource: "history", namespaces: [])
        #expect(PageWebView.debugRoot(for: history, environment: ["CMUX_NEXT_PAGE_ROOT_cmux_history": "/tmp/dev-history"])?.path
            == "/tmp/dev-history", "the dev loop's override still works for other pages")
        #endif
    }

    /// SECURITY (cmux#37286): a bundled-only page gets no server URL, whatever the request.
    @Test func neverServesABundledOnlyPage() throws {
        let server = PageDevServer(root: try #require(URL(string: "http://127.0.0.1:4190/")))
        for id in PageDevServer.bundledOnlyPageIDs {
            let page = PageDescriptor(id: id, resource: String(id.dropFirst("cmux.".count)), namespaces: [])
            for path in ["", "index.html", "assets/main.js"] {
                let request = try #require(URL(string: "cmux-page://\(id)/\(path)"))
                #expect(server.url(for: request, page: page) == nil, "\(id) /\(path)")
            }
        }
    }
}
