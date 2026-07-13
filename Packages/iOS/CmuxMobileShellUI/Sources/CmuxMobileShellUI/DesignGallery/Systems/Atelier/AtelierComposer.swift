#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Provides Atelier's fixed warm-glass conversational composer pill.
struct AtelierComposer: View {
    let placeholder: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        HStack(spacing: 10) {
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(AtelierPressButtonStyle())

            Text(placeholder)
                .font(.system(size: 16))
                .foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: {}) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accentForeground)
                    .frame(width: 44, height: 44)
                    .background(theme.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(AtelierPressButtonStyle())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .mobileGlassPill()
        .background(theme.background.opacity(0.50), in: Capsule())
        .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
#endif
