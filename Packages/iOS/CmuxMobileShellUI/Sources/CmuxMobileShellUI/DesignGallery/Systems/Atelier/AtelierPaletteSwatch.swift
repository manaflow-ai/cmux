#if DEBUG
import SwiftUI

/// Labels one exact Atelier palette token with its color and hexadecimal value.
struct AtelierPaletteSwatch: View {
    let name: String
    let hex: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .frame(width: 52, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.hairline, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(theme.textPrimary)
                Text(hex)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }
}
#endif
