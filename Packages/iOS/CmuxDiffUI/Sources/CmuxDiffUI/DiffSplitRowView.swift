import SwiftUI

struct DiffSplitRowView: View {
    let row: SplitDiffRow
    let highlights: [String: HighlightedCode]
    let expand: @MainActor (DiffContextExpansionRequest.Direction) -> Void

    var body: some View {
        if let spanning = row.spanning {
            if spanning.kind == .hunkHeader {
                DiffHunkHeaderView(row: spanning, expand: expand)
            } else {
                Text(noNewlineLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
        } else {
            HStack(spacing: 0) {
                DiffSplitCodeColumn(
                    row: row.old,
                    highlighted: row.old.flatMap { highlights[$0.id] },
                    isOldSide: true
                )
                Divider()
                DiffSplitCodeColumn(
                    row: row.new,
                    highlighted: row.new.flatMap { highlights[$0.id] },
                    isOldSide: false
                )
            }
        }
    }

    private var noNewlineLabel: String {
        DiffLocalized().string("diff.row.noNewline", defaultValue: "No newline at end of file")
    }
}
