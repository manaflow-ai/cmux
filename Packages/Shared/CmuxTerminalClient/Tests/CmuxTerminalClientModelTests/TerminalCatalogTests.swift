import CmuxTerminalClientModel
import Foundation
import Testing

@Suite struct TerminalCatalogTests {
    @Test func listDecodesIdAndOptionalNameAndIgnoresUnknownFields() throws {
        let json = Data(#"[{"id":"term_a","name":"shell","cwd":"/root"},{"id":"term_b"}]"#.utf8)
        let terminals = try TerminalCatalogDecoding.terminals(fromListResult: json)
        #expect(terminals == [TerminalSummary(id: "term_a", name: "shell"), TerminalSummary(id: "term_b")])
    }

    @Test func createReturnsTheTerminalPath() throws {
        // A live daemon's MutationResult<CreatedPath> for initial_content: terminal.
        let json = Data("""
        {"generation":"9ded6c40","replayed":false,"revision":"3","value":{"kind":"terminal","pane_id":"pane_1","screen_id":"screen_1","tab_id":"tab_1","terminal_id":"term_f8719e501df7aa2dbaa70b78d20d0822","workspace_id":"ws_1"}}
        """.utf8)
        #expect(try TerminalCatalogDecoding.createdTerminalID(fromCreateResult: json) == "term_f8719e501df7aa2dbaa70b78d20d0822")
    }

    @Test func createWithoutTerminalIsAnError() {
        // initial_content: empty returns CreatedWorkspaceOnly, which has no terminal.
        let json = Data(#"{"generation":"9ded6c40","replayed":false,"revision":"3","value":{"kind":"workspace","workspace_id":"ws_1"}}"#.utf8)
        #expect(throws: TerminalCatalogError.missingCreatedTerminal) {
            try TerminalCatalogDecoding.createdTerminalID(fromCreateResult: json)
        }
    }

    @Test func outputEventsMapKindsAndRejectUnknownOnes() {
        #expect(TerminalOutputEvent(kind: 1, bytes: Data([0x24]), cols: 80, rows: 24) == .snapshot(replay: Data([0x24]), cols: 80, rows: 24))
        #expect(TerminalOutputEvent(kind: 2, bytes: Data([0x41]), cols: 0, rows: 0) == .output(Data([0x41])))
        #expect(TerminalOutputEvent(kind: 3, bytes: Data(), cols: 100, rows: 30) == .resized(cols: 100, rows: 30))
        #expect(TerminalOutputEvent(kind: 4, bytes: Data(), cols: 0, rows: 0) == .exited)
        #expect(TerminalOutputEvent(kind: 9, bytes: Data(), cols: 0, rows: 0) == nil)
    }
}

