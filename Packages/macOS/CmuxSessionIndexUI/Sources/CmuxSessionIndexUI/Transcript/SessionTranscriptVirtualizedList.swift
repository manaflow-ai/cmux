public import SwiftUI

import CmuxSessionIndex

/// A lazily-rendered, scrollable list of transcript display rows.
///
/// `Equatable` compares only `rows`: `roleLabel` is a stable app-bundle resolver tied to
/// the preview's lifetime, so equal `rows` means an unchanged body. Keeping it `Equatable`
/// preserves the `LazyVStack` snapshot-boundary optimization (no store reference below the
/// list, per the Sessions-panel CPU-spin contract).
struct SessionTranscriptVirtualizedList: View, Equatable {
    let rows: [SessionTranscriptDisplayRow]
    let roleLabel: (SessionTranscriptRole) -> String

    static func == (
        lhs: SessionTranscriptVirtualizedList,
        rhs: SessionTranscriptVirtualizedList
    ) -> Bool {
        lhs.rows == rhs.rows
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SessionTranscriptTurnView(row: row, roleLabel: roleLabel(row.role))
                        .id(row.id)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.018))
    }
}
