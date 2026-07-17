internal import SwiftUI

struct DiffExpansionGapView: View {
    let file: DiffFileSnapshot
    let row: DiffRowSnapshot
    let expand: @MainActor @Sendable (String, String, ContextExpansionDirection) -> Void
    @Environment(\.diffTheme) private var theme

    var body: some View {
        if let gap = row.expansionGap {
            HStack(spacing: 10) {
                Button { expand(file.path, gap.id, .up) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(gap.newEnd == nil)
                .accessibilityLabel(String(localized: "diff.context.expandUp", defaultValue: "Expand up", bundle: .module))

                if let count = gap.knownLineCount, count <= 40 {
                    Button { expand(file.path, gap.id, .all) } label: {
                        Image(systemName: "arrow.up.and.down")
                    }
                    .accessibilityLabel(String(localized: "diff.context.expandAll", defaultValue: "Expand all context", bundle: .module))
                }

                Button { expand(file.path, gap.id, .down) } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel(String(localized: "diff.context.expandDown", defaultValue: "Expand down", bundle: .module))

                Text(contextLabel(gap))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.hunkBackground)
        }
    }

    private func contextLabel(_ gap: DiffExpansionGap) -> String {
        guard let count = gap.knownLineCount else {
            return String(localized: "diff.context.more", defaultValue: "More lines", bundle: .module)
        }
        let format = String(localized: "diff.context.hiddenLines", defaultValue: "%lld hidden lines", bundle: .module)
        return String(format: format, locale: .current, count)
    }
}
