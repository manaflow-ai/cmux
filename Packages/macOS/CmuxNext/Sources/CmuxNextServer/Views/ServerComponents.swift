import SwiftUI

/// The card fill and hairline used by the dashboard and the pairing views.
struct CardBackground: ViewModifier {
    var radius: CGFloat = ServerMetrics.cardRadius
    @Environment(\.serverColors) private var colors
    @Environment(\.serverLineWidth) private var line

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colors.fill)
                .strokeBorder(colors.separator.opacity(0.6), lineWidth: line * 0.5))
    }
}

extension View {
    func card(radius: CGFloat = ServerMetrics.cardRadius) -> some View { modifier(CardBackground(radius: radius)) }
}

/// A thin separator that disappears under `appearance.borders = none`.
struct ServerDivider: View {
    @Environment(\.serverColors) private var colors
    @Environment(\.serverLineWidth) private var line

    var body: some View {
        Rectangle().fill(colors.separator).frame(height: 0.5 * line)
    }
}

/// The store version line at the bottom of a panel.
struct StoreFooter: View {
    let store: ServerStoreInfo
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: "cmux \(store.version) · \(store.channel)")
            if store.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8.5)).help(ServerStrings.pinned)
            }
            Spacer()
        }
        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(colors.tertiary)
        .padding(.horizontal, 8)
    }
}
