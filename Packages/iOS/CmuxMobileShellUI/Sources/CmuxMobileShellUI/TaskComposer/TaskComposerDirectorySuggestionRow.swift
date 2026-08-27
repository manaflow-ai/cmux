#if os(iOS)
import SwiftUI

/// A standard picker row for one suggested or found folder: folder glyph,
/// name over its parent path, and a trailing checkmark when it is the
/// current selection, matching the system checkmark-list pattern.
struct TaskComposerDirectorySuggestionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let displayPath: TaskComposerDirectoryDisplayPath
    let sourceLabel: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayPath.name)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                if let parentPath = displayPath.parentPath {
                    Text(parentPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let sourceLabel, !dynamicTypeSize.isAccessibilitySize {
                Text(sourceLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
