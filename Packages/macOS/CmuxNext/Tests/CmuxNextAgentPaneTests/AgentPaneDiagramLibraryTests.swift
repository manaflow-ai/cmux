import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Charts in replies draw with the markdown viewer's bundled Vega, which the pane's scheme handler
/// serves as one same-origin script (`cmux-agent://pane/__lib/vega.js`), as the markdown page gets
/// it. Mermaid is not served here: the pane draws it through the shared diagram worker.
@Suite struct AgentPaneDiagramLibraryTests {
    @Test func thePaneGetsVegaFromTheViewersLibrariesAndNothingElse() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pane-libs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("VEGA".utf8).write(to: folder.appending(path: "vega.min.js"))
        try Data("LITE".utf8).write(to: folder.appending(path: "vega-lite.min.js"))
        try Data("MERMAID".utf8).write(to: folder.appending(path: "mermaid.min.js"))

        // The same bytes the markdown page gets for `__lib/vega.js`.
        let shared = try #require(await MarkdownPageResource.library("vega.js", in: folder))
        #expect(String(decoding: shared, as: UTF8.self) == "VEGA\n;\nLITE")

        let url = try #require(URL(string: "cmux-agent://pane/__lib/vega.js"))
        #expect(await AgentPaneSchemeHandler.library(for: url, in: folder) == shared)
        #expect(await AgentPaneSchemeHandler.library(for: try #require(URL(string: "cmux-agent://pane/__lib/mermaid.js")), in: folder) == nil)
        #expect(await AgentPaneSchemeHandler.library(for: try #require(URL(string: "cmux-agent://pane/__lib/../vega.min.js")), in: folder) == nil)
        #expect(await AgentPaneSchemeHandler.library(for: try #require(URL(string: "cmux-agent://other/__lib/vega.js")), in: folder) == nil)
        #expect(AgentPaneSchemeHandler.headers(for: URL(fileURLWithPath: "/pane/vega.js"), length: 4)["Content-Type"] == "text/javascript")
    }
}
