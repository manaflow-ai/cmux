#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Provides Meridian's glass capsule chat composer with tactile inert controls.
struct MeridianComposer: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            iconButton(symbol: "plus", label: "Add attachment")

            Text("Message")
                .font(.body)
                .foregroundStyle(theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)

            iconButton(symbol: "waveform", label: "Voice input")
        }
        .padding(6)
        .frame(minHeight: 56)
        .mobileGlassPill()
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private func iconButton(symbol: String, label: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(theme.label)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(MeridianPressButtonStyle())
        .accessibilityLabel(label)
    }
}
#endif
