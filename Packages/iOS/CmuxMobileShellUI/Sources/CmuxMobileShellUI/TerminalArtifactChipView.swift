#if os(iOS)
import SwiftUI

/// A value-driven terminal overlay that opens the visible-file gallery.
struct TerminalArtifactChipView: View {
    let count: Int
    let onTap: @MainActor () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))

                Text(localizedCount)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "terminal.artifact.chip.accessibility_label",
            defaultValue: "Open files in view",
            bundle: .module
        ))
        .accessibilityValue(localizedCount)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileTerminalArtifactChip")
    }

    private var localizedCount: String {
        let format = String(
            localized: "terminal.artifact.chip.count",
            defaultValue: "%lld files",
            bundle: .module
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }
}
#endif
