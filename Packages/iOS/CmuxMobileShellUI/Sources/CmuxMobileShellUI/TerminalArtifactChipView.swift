#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A value-driven terminal overlay that opens the visible-file gallery, or,
/// on an SSH terminal (`count == nil`), the computer's file browser.
struct TerminalArtifactChipView: View {
    /// Files in view, or `nil` for the SSH "Files" chip, which is always
    /// available because it browses the server rather than paths on screen.
    let count: Int?
    let onTap: @MainActor () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: count == nil ? "folder" : "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .modifier(TerminalArtifactChipSurfaceModifier())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(count == nil ? "" : title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(count == nil ? "ssh.files" : "MobileTerminalArtifactChip")
    }

    private var title: String {
        guard let count else {
            return L10n.string("mobile.ssh.files.chip", defaultValue: "Files")
        }
        return localizedCount(count)
    }

    private var accessibilityLabel: String {
        guard count != nil else {
            return L10n.string(
                "mobile.ssh.files.chip.accessibilityLabel",
                defaultValue: "Browse files in the current folder"
            )
        }
        return String(
            localized: "terminal.artifact.chip.accessibility_label",
            defaultValue: "Open files in view",
            bundle: .module
        )
    }

    private func localizedCount(_ count: Int) -> String {
        let attributed = AttributedString(
            localized: "^[\(count) file](inflect: true)",
            bundle: .module
        )
        return String(attributed.characters)
    }
}
#endif
