import CmuxNextBrowser
@testable import CmuxNextApp
import Foundation
import Testing

/// The New Tab field's typed intent table (`webviews/test/fixtures/new-tab-intents.json`), the
/// same rows the page's `classifyNewTabInput` passes. The CLI, MCP and palette (Swift) and the page
/// (TypeScript) must open the same thing for the same text: `go/gday` loads `http://go/gday` from
/// both (user 2026-10-20, go/ links "just work" in Chrome).
@Suite struct NewTabIntentTableTests {
    private struct Table: Decodable {
        struct Row: Decodable {
            let input: String
            let intent: NewTabIntent
        }
        let home: String
        let rows: [Row]
    }

    private static func table() throws -> Table {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent() // CmuxNextAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CmuxNext
            .deletingLastPathComponent() // macOS
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appending(path: "webviews/test/fixtures/new-tab-intents.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: fixture))
    }

    @Test func everyRowMatchesThePage() throws {
        let table = try Self.table()
        let home = URL(filePath: table.home, directoryHint: .isDirectory)
        #expect(table.rows.count > 60)
        for row in table.rows {
            #expect(NewTabIntent.classify(row.input, home: home) == row.intent, "input \(row.input.debugDescription)")
        }
    }

    @Test func goLinksOpenOverHTTP() {
        #expect(NewTabIntent.classify("go/gday", home: nil) == .url("http://go/gday"))
        #expect(NewTabIntent.classify("go", home: nil) == .prompt("go"))
    }
}
