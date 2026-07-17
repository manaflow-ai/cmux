import SwiftUI

struct DiffTreeRowView: View {
    let row: DiffTreeRowSnapshot
    let select: @MainActor () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                switch row.kind {
                case let .directory(isExpanded):
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .frame(width: 14)
                    Image(systemName: isExpanded ? "folder.fill.badge.minus" : "folder.fill")
                        .foregroundStyle(.secondary)
                case let .file(status):
                    DiffStatusBadge(status: status)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if case .directory = row.kind {
                        Text(fileCountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text("+\(row.additions)").foregroundStyle(.green)
                    Text("−\(row.deletions)").foregroundStyle(.red)
                }
                .font(.caption2.monospacedDigit())
            }
            .contentShape(Rectangle())
            .opacity(row.isViewed ? 0.5 : 1)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private var fileCountLabel: String {
        DiffLocalized().format(
            "diff.tree.fileCount",
            defaultValue: "%lld files",
            Int64(row.fileCount)
        )
    }
}
