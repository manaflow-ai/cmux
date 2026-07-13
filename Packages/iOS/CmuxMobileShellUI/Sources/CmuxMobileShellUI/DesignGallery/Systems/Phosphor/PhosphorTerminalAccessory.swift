#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Provides Phosphor's glass-backed terminal command input and send target.
struct PhosphorTerminalAccessory: View {
    @Binding var command: String

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        HStack(spacing: 8) {
            Text("$")
                .font(typography.dataSemibold)
                .foregroundStyle(theme.accent)

            TextField("Send command…", text: $command)
                .font(typography.data)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 44)

            Button(action: {}) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.isDark ? theme.textPrimary : theme.bg1)
                    .frame(width: 44, height: 44)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PhosphorPressButtonStyle())
            .accessibilityLabel("Send command")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .mobileGlassField(cornerRadius: 12)
    }
}
#endif
