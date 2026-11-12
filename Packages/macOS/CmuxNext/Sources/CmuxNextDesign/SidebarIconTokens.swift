public import CoreGraphics

/// A density's own sidebar icon geometry (Lawrence 2026-11-12: "make sure i can control icons in sidebar, sizing,
/// positioning, everything"): exact values in `DensityTokens.tokens` under ``Name``, nil where the density follows the
/// sidebar's derived rule. The Density Lab sets them; a custom density stores them in cmux.json like any token.
public nonisolated struct SidebarIconTokens: Sendable, Equatable {
    /// A token's key in `DensityTokens.tokens`.
    public enum Name: String, CaseIterable, Sendable {
        /// The side every row's leading glyph ink fills (favicons, symbols, Home's house, pins).
        case size = "sidebarIconSize"
        /// The leading icon column's width; the title starts after it.
        case column = "sidebarIconColumn"
        /// The gap from the icon column to the title.
        case gap = "sidebarIconGap"
        /// The row content's inset from the row fill's leading edge (and trailing edge).
        case inset = "sidebarRowInset"
        /// Moves every leading glyph right (negative: left) without moving the title.
        case x = "sidebarIconX"
        /// Moves every leading glyph down (negative: up).
        case y = "sidebarIconY"
    }

    public var size: CGFloat?
    public var column: CGFloat?
    public var gap: CGFloat?
    public var inset: CGFloat?
    public var x: CGFloat
    public var y: CGFloat

    /// The tokens `density` sets, each through `scale` (the interface scale).
    public init(_ density: DensityTokens, scale: (CGFloat) -> CGFloat = { $0 }) {
        func value(_ name: Name) -> CGFloat? { density.tokens[name.rawValue].map { scale(CGFloat($0)) } }
        size = value(.size)
        column = value(.column)
        gap = value(.gap)
        inset = value(.inset)
        x = value(.x) ?? 0
        y = value(.y) ?? 0
    }

    /// The active density's sidebar icon tokens at the interface scale.
    @MainActor public static var current: SidebarIconTokens { SidebarIconTokens(Metrics.tokens, scale: Metrics.scale) }
}
