public import CmuxTheme

/// A part of the window whose background the user may change
/// (`appearance.surfaces.<surface>` in cmux.json, Lawrence R55;
/// plans/cmux-next/surface-backgrounds.md). Its raw value is the cmux.json
/// key. A Chromium page is not a surface: a page paints itself.
public nonisolated enum SurfaceKind: String, CaseIterable, Sendable, Hashable {
    case sidebar
    case tabBar
    case terminal
    case agentPane
    case settings
    case newTabPage
    case home
    case browserChrome
    case docks
}

/// One surface's override: a color, an opacity, or both. Both nil is no
/// override (the window's one backdrop, R48).
public nonisolated struct SurfaceBackground: Hashable, Sendable {
    /// `appearance.surfaces.<surface>.color` (`#RRGGBB[AA]`); nil: the
    /// window's color (the theme background).
    public var color: ThemeRGB?
    /// `appearance.surfaces.<surface>.opacity`, 0...1; nil: the window's
    /// opacity (`appearance.backgroundOpacity`).
    public var opacity: Double?

    public init(color: ThemeRGB? = nil, opacity: Double? = nil) {
        self.color = color
        self.opacity = opacity.map { min(max($0, 0), 1) }
    }

    public var isEmpty: Bool { color == nil && opacity == nil }
}

/// Every surface override, and the one resolver each surface's owner paints
/// from (never a view's own color math).
///
/// A surface with no override keeps R48: it shows the window's one
/// backdrop, so its owner paints what it painted before (``fill(for:tokens:)``
/// is nil). With an override the owner paints the returned color over the
/// window's backdrop:
///
/// - With a color: that color, at the override's opacity (or the window's
///   opacity when unset) times the color's own alpha.
/// - With only an opacity: the theme background, at the alpha that makes
///   the surface cover the backdrop exactly that much. The window's tint is
///   under every surface, so a surface can be more opaque than the window,
///   never less: an opacity at or below the window's paints nothing.
///
/// ```swift
/// let fill = SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(color: red)])
///     .fill(for: .sidebar, tokens: tokens)   // red at the window's opacity
/// ```
public nonisolated struct SurfaceBackgrounds: Hashable, Sendable {
    public var overrides: [SurfaceKind: SurfaceBackground]

    public init(overrides: [SurfaceKind: SurfaceBackground] = [:]) {
        self.overrides = overrides.filter { !$0.value.isEmpty }
    }

    /// No override anywhere: every surface shows the window's backdrop.
    public static let none = SurfaceBackgrounds()

    public subscript(kind: SurfaceKind) -> SurfaceBackground? { overrides[kind] }

    /// What `kind`'s owner paints over the window's backdrop, or nil when
    /// the surface has no override.
    ///
    /// - Parameter kind: The surface.
    /// - Parameter tokens: The theme tokens of the surface's scope (its
    ///   background color, `background-opacity` and blur).
    public func fill(for kind: SurfaceKind, tokens: ThemeTokens) -> ThemeRGB? {
        guard let override = overrides[kind], !override.isEmpty else { return nil }
        let window = WindowBackdrop(tokens).tintOpacity
        if let color = override.color {
            return color.withAlpha(color.alpha * (override.opacity ?? window))
        }
        let target = override.opacity ?? window
        // Over the tint (alpha `window`), alpha x of the same color covers
        // window + x * (1 - window) = target.
        let alpha = window >= 1 || target <= window ? 0 : (target - window) / (1 - window)
        return tokens.surfaceBackground.withAlpha(alpha)
    }

    /// `fill(for:tokens:)` laid over an opaque `base`, for owners that
    /// must paint an opaque color (a docked column hides what scrolls under
    /// it); `base` itself without an override.
    public func opaqueFill(for kind: SurfaceKind, tokens: ThemeTokens, base: ThemeRGB) -> ThemeRGB {
        guard let fill = fill(for: kind, tokens: tokens) else { return base }
        return fill.composited(over: base.withAlpha(1))
    }

    /// Whether the terminal has an override. Terminals then draw a
    /// transparent default background in every window, so their owner's
    /// fill shows behind the cells (`GhosttyRuntimeSurfacePolicy`).
    public var overridesTerminal: Bool { overrides[.terminal] != nil }
}
