import CmuxNextDesign
import SwiftUI

/// The store's cards (apps and features): glass over the page, tinted with the theme's hover
/// fill, a hairline rim, and the selection tint while hovered. Reduce Transparency turns the
/// material solid on its own.
struct AppStoreCardStyle: ViewModifier {
    var hovered = false
    @Environment(\.appSceneColors) private var colors

    static let radius: CGFloat = 12
    /// The grid's narrowest card; columns are added as the window widens.
    static let minimumWidth: CGFloat = 240

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        content
            .background(shape.fill(hovered ? colors.selection : colors.hover))
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(colors.separator, lineWidth: Borders.width(1)))
    }
}

extension View {
    func appStoreCard(hovered: Bool = false) -> some View { modifier(AppStoreCardStyle(hovered: hovered)) }
}

/// The store's responsive card grid: as many columns as fit, each at least
/// ``AppStoreCardStyle/minimumWidth``.
struct AppStoreCardGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: AppStoreCardStyle.minimumWidth), spacing: Metrics.space4, alignment: .top)],
                  alignment: .leading, spacing: Metrics.space4, content: content)
    }
}
