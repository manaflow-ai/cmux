#if os(iOS)
import SwiftUI

struct TaskComposerDirectorySuggestionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let displayPath: TaskComposerDirectoryDisplayPath
    let sourceLabel: String
    let context: String?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayPath.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                if let parentPath = displayPath.parentPath {
                    Text(parentPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                        if let context {
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        Text(sourceLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                        if let context {
                            Text(verbatim: "·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}
#endif
