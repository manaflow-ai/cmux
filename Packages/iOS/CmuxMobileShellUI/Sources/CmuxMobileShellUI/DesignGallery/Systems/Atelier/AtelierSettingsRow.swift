#if DEBUG
import SwiftUI

/// Lays out one roomy settings value row with an optional symbol.
struct AtelierSettingsRow: View {
    let label: String
    let value: String
    let symbol: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}
#endif
