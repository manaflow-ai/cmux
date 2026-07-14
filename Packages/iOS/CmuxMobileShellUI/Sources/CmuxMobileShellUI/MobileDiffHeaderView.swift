#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Sticky native controls above the full-size web diff surface.
struct MobileDiffHeaderView: View {
    let path: String
    let index: Int
    let total: Int
    let back: () -> Void
    let openTree: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 36)
            }
            .accessibilityLabel(
                L10n.string("mobile.diff.backToChanges", defaultValue: "Back to changes")
            )

            Button(action: openTree) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.string("mobile.diff.openChangedFiles", defaultValue: "Open changed files")
            )

            Text(positionLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            Button(action: previous) {
                Image(systemName: "chevron.up")
                    .frame(width: 32, height: 36)
            }
            .disabled(index <= 0 || total <= 1)
            .accessibilityLabel(
                L10n.string("mobile.diff.previousFile", defaultValue: "Previous file")
            )

            Button(action: next) {
                Image(systemName: "chevron.down")
                    .frame(width: 32, height: 36)
            }
            .disabled(index < 0 || index + 1 >= total)
            .accessibilityLabel(
                L10n.string("mobile.diff.nextFile", defaultValue: "Next file")
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial)
    }

    private var fileName: String {
        MobileDiffPath(path).fileName
    }

    private var directory: String {
        MobileDiffPath(path).directory
    }

    private var positionLabel: String {
        String(
            format: L10n.string("mobile.diff.positionFormat", defaultValue: "%d of %d"),
            max(0, index) + 1,
            total
        )
    }
}
#endif
