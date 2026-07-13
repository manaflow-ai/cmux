#if DEBUG
import SwiftUI

/// Encodes one gallery state with a tint, glyph, and explicit word label.
struct PhosphorStatusChip: View {
    let state: GalleryAgentState

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)
        let color = theme.statusColor(state)

        HStack(spacing: 4) {
            Image(systemName: theme.statusSymbol(state))
                .font(.system(size: 10, weight: .bold))
            Text(theme.statusLabel(state))
                .font(typography.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
#endif
