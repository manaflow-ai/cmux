#if DEBUG
import SwiftUI

/// Wraps a settings section in Atelier's serif label and warm card surface.
struct AtelierSettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(theme.textPrimary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.hairline, lineWidth: 1)
            }
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 2)
        }
    }
}
#endif
