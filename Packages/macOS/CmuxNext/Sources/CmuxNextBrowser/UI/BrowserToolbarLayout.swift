import CoreGraphics

/// How the browser toolbar collapses as its pane narrows:
///
/// 1. pinned extension buttons move into the Extensions menu, last pinned
///    first, while the omnibar would be narrower than `preferredAddress`;
/// 2. then the omnibar shrinks from `preferredAddress` to `minimumAddress`;
/// 3. then Forward hides, and the omnibar takes what is left.
///
/// Back, Reload, the omnibar and the Extensions button always stay.
nonisolated struct BrowserToolbarLayout: Equatable, Sendable {
    /// Pinned extension buttons that fit (the rest are in the menu).
    var visiblePinned: Int
    var showsForward: Bool

    struct Metrics: Equatable, Sendable {
        var button: CGFloat
        var navigationSpacing: CGFloat
        var extensionSpacing: CGFloat
        var inset: CGFloat
        var margin: CGFloat
        /// Omnibar width kept before an extension button moves to the menu.
        var preferredAddress: CGFloat
        /// Omnibar width kept before Forward hides.
        var minimumAddress: CGFloat
    }

    static func resolve(width: CGFloat, pinned: Int, showsExtensions: Bool, metrics m: Metrics) -> BrowserToolbarLayout {
        let fixed = 2 * m.inset + 2 * m.margin
        func navigation(_ forward: Bool) -> CGFloat {
            forward ? 3 * m.button + 2 * m.navigationSpacing : 2 * m.button + m.navigationSpacing
        }
        func extensions(_ count: Int) -> CGFloat {
            guard showsExtensions else { return 0 }
            return CGFloat(count + 1) * m.button + CGFloat(count) * m.extensionSpacing
        }
        let maxPinned = showsExtensions ? pinned : 0
        for count in stride(from: maxPinned, to: 0, by: -1)
        where fixed + navigation(true) + extensions(count) + m.preferredAddress <= width {
            return BrowserToolbarLayout(visiblePinned: count, showsForward: true)
        }
        let forward = fixed + navigation(true) + extensions(0) + m.minimumAddress <= width
        return BrowserToolbarLayout(visiblePinned: 0, showsForward: forward)
    }

    /// The omnibar width this layout leaves at `width`.
    static func addressWidth(width: CGFloat, layout: BrowserToolbarLayout, showsExtensions: Bool, metrics m: Metrics) -> CGFloat {
        let navigation = layout.showsForward ? 3 * m.button + 2 * m.navigationSpacing : 2 * m.button + m.navigationSpacing
        let count = layout.visiblePinned
        let extensions = showsExtensions ? CGFloat(count + 1) * m.button + CGFloat(count) * m.extensionSpacing : 0
        return width - 2 * m.inset - 2 * m.margin - navigation - extensions
    }
}
