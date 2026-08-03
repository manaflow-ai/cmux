#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Live count of computers and terminal targets available to GPT Voice.
struct GPTVoiceTargetSummaryView: View {
    let computerCount: Int
    let terminalCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: terminalCount > 0
                ? "macbook.and.iphone"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(terminalCount > 0 ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminalCount > 0
                    ? L10n.string(
                        "mobile.voiceMode.gpt.ready",
                        defaultValue: "Ready across your computers"
                    )
                    : L10n.string(
                        "mobile.voiceMode.gpt.noTargets",
                        defaultValue: "No compatible terminals"
                    ))
                    .font(.subheadline.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .accessibilityIdentifier("MobileGPTVoiceTargetSummary")
    }

    private var summary: String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.voiceMode.gpt.targetCountFormat",
                defaultValue: "%lld terminals on %lld computers"
            ),
            Int64(terminalCount),
            Int64(computerCount)
        )
    }
}
#endif
