#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Compact summary of the Mac terminal that will receive speech.
struct VoiceModeDestinationView: View {
    let workspaceTitle: String?
    let surfaceTitle: String?
    let hasTerminal: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasTerminal ? "terminal" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasTerminal ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(hasTerminal
                    ? surfaceTitle ?? L10n.string("mobile.voiceMode.terminal", defaultValue: "Terminal")
                    : L10n.string("mobile.voiceMode.noTerminalFocused", defaultValue: "No terminal focused"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(hasTerminal
                    ? workspaceTitle ?? L10n.string("mobile.voiceMode.target", defaultValue: "Target")
                    : L10n.string("mobile.voiceMode.clickTerminal", defaultValue: "Click a terminal pane on your Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .accessibilityIdentifier("MobileVoiceModeDestination")
    }
}
#endif
