import SwiftUI

/// Renders a single Source Control status group from immutable row snapshots.
struct SourceControlGroupView: View {
    let group: SourceControlGroup
    let resources: [SourceControlResourceRow]
    let onOpenDiffViewer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Text(resources.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(resources) { resource in
                Button {
                    onOpenDiffViewer(resource.path)
                } label: {
                    HStack(spacing: 8) {
                        Text(resource.statusLetter)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(
                                resource.status == .untracked ? Color.secondary : Color.orange
                            )
                            .frame(width: 14)
                        Text(resource.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        String(localized: "sourceControl.resource.accessibilityLabel", defaultValue: "%@, %@"),
                        resource.relativePath,
                        resource.statusLetter
                    )
                )
            }
        }
    }
}
