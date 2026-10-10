import Foundation
import Testing
@testable import CmuxNextDaemon

/// `columns[].rows` (`rows-v1`): a column with two or more rows lists them
/// top to bottom; a column with one row (and an older daemon) omits them.
struct RowSnapshotDecodingTests {
    private func column(_ json: String) throws -> ColumnSnapshot {
        try JSONDecoder().decode(ColumnSnapshot.self, from: Data(json.utf8))
    }

    @Test func decodesRowsTopToBottom() throws {
        let decoded = try column("""
        {"id":14,"width":1.0,"layout":{"type":"split","split":41,"dir":"down","ratio":0.6,"a":{"type":"leaf","pane":4},"b":{"type":"leaf","pane":5}},
         "rows":[{"id":40,"height":600,"layout":{"type":"leaf","pane":4}},{"id":41,"height":400,"layout":{"type":"leaf","pane":5}}]}
        """)
        #expect(decoded.rows == [
            RowSnapshot(id: 40, height: 600, layout: .leaf(4)),
            RowSnapshot(id: 41, height: 400, layout: .leaf(5)),
        ])
        #expect(decoded.layout.paneIDs == [4, 5])
    }

    @Test func aColumnWithOneRowOrAnOlderDaemonHasNoRows() throws {
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4}}"#).rows.isEmpty)
        #expect(try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"rows":null}"#).rows.isEmpty)
    }

    /// A malformed `rows` field never drops the column: it falls back to
    /// the compat chain in `layout`, as an older client reads it.
    @Test func malformedRowsFallBackToTheCompatChain() throws {
        let decoded = try column(#"{"id":9,"width":0.3,"layout":{"type":"leaf","pane":4},"rows":[{"id":"x"}]}"#)
        #expect(decoded.rows.isEmpty)
        #expect(decoded.layout == .leaf(4))
    }

    @Test func rowsIsAnOptionalCapability() {
        #expect(DaemonCapabilities.shared.rows == "rows-v1")
        #expect(DaemonCapabilities.shared.optional.contains("rows-v1"))
    }
}
