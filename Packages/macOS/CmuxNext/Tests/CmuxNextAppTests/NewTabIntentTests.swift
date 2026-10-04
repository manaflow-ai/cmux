import Foundation
import Testing
@testable import CmuxNextApp

/// The new tab field's typed intent. The table is shared with the page's
/// classifier (`webviews/src/agent-session/acpmux/newTabIntent.test.ts`),
/// so the CLI and MCP path decides exactly as the field does.
@Suite struct NewTabIntentTests {
    struct Fixture: Decodable {
        struct Row: Decodable {
            var input: String
            var mode: NewTabIntent.Mode?
            var intent: NewTabIntent
        }
        var home: String
        var rows: [Row]
    }

    static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CmuxNextAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CmuxNext
            .deletingLastPathComponent() // macOS
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appending(path: "webviews/test/fixtures/new-tab-intents.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func everyRowOfTheSharedTableClassifiesAsThePageDoes() throws {
        let fixture = try Self.fixture()
        #expect(fixture.rows.count > 50)
        let home = URL(filePath: fixture.home, directoryHint: .isDirectory)
        for row in fixture.rows {
            let mode = row.mode ?? .ask
            let intent = NewTabIntent.classify(row.input, mode: mode, home: home)
            #expect(intent == row.intent, "\(row.input.debugDescription) in \(mode)")
        }
    }

    @Test func theModeNeverChangesACommandOrAnAddress() {
        for input in ["!make", "github.com", "localhost:3000"] {
            #expect(NewTabIntent.classify(input, mode: .ask) == NewTabIntent.classify(input, mode: .search))
        }
    }
}
