@testable import CmuxNextPages
import Foundation
import Testing

/// ``PageDevServer/pageIDs`` against the pages the webviews dev server builds.
struct PageDevServerTests {
    /// Every `webviews/src/pages/<resource>/` with a `main.tsx` (the dev server's entries) is a
    /// page the server serves, as `cmux.<resource>`, and the list names no other page: a new page
    /// would otherwise keep its bundled files under `web-dev.json`.
    @Test func servesExactlyTheWebviewsPages() throws {
        let pages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("webviews/src/pages")
        let resources = try FileManager.default.contentsOfDirectory(atPath: pages.path)
            .filter { FileManager.default.fileExists(atPath: pages.appendingPathComponent("\($0)/main.tsx").path) }
        #expect(!resources.isEmpty, "no pages under \(pages.path)")
        #expect(Set(resources.map { "cmux.\($0)" }) == PageDevServer.pageIDs)
    }
}
