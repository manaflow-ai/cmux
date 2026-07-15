import SwiftUI

struct DiffHunkHeaderView: View {
    @Environment(\.diffTheme) private var theme
    let row: DiffRowSnapshot
    let expand: @MainActor (DiffContextExpansionRequest.Direction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(row.text)
                .font(.caption.monospaced())
                .foregroundStyle(.blue)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            expansionButton(systemImage: "arrow.up.to.line", direction: .up, label: expandUpLabel)
            expansionButton(systemImage: "arrow.down.to.line", direction: .down, label: expandDownLabel)
            expansionButton(systemImage: "arrow.up.and.down", direction: .all, label: expandAllLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.hunkFill)
    }

    private func expansionButton(
        systemImage: String,
        direction: DiffContextExpansionRequest.Direction,
        label: String
    ) -> some View {
        Button { expand(direction) } label: {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var expandUpLabel: String {
        DiffLocalized().string("diff.hunk.expandUp", defaultValue: "Expand context above")
    }

    private var expandDownLabel: String {
        DiffLocalized().string("diff.hunk.expandDown", defaultValue: "Expand context below")
    }

    private var expandAllLabel: String {
        DiffLocalized().string("diff.hunk.expandAll", defaultValue: "Expand all context")
    }
}
