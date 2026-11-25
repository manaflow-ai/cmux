import SwiftUI
import CmuxNextDesign

/// The card fill and hairline of the Add Machine card.
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
