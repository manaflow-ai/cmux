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
    /// page the server serves, as `cmux.<resource>`, and the list names no other page: a new page
    /// would otherwise keep its bundled files under `web-dev.json`.
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
        #expect(Set(resources.map { "cmux.\($0)" }) == PageDevServer.pageIDs)
    }
}
