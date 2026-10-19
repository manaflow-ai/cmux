import AppKit
import Testing
@testable import CmuxNextAgentPane

/// Edit and Resend on a prompt hands the page the prompt's row with its text, so the page opens the
/// prompt's editor in its bubble (cx-ncc.60's in-place edit, Codex parity) where the chat can fork
/// before it, and puts the text back in the composer elsewhere.
@Suite
@MainActor
struct AgentPaneEditPromptMenuTests {
    static func choose(_ report: [String: Any]) throws -> [(text: String, row: String?)] {
        var edits: [(text: String, row: String?)] = []
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in },
                                                    editPrompt: { edits.append(($0, $1)) }))
        let item = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.editAndResend },
                                "\(menu.items.map(\.title))")
        _ = (item.target as? NSObject)?.perform(item.action)
        return edits
    }

    @Test func aPromptsEditNamesItsRow() throws {
        let edits = try Self.choose(["text": "Now cover it with a test", "promptRowId": "user-4"])
        #expect(edits.map(\.text) == ["Now cover it with a test"])
        #expect(edits.map(\.row) == ["user-4"])
    }

    @Test func anOlderPageReportsNoRow() throws {
        let edits = try Self.choose(["text": "Now cover it with a test"])
        #expect(edits.map(\.row) == [nil])
    }
}
