public import CmuxTheme
public import CmuxNextDesignTokens

/// A part of the window whose background the user may change
/// (`appearance.surfaces.<surface>` in cmux.json, Lawrence R55;
/// plans/cmux-next/surface-backgrounds.md). Its raw value is the cmux.json
/// key. A real web page is not a surface; cmux-owned internal pages are.
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
    /// Native and bundled internal pages such as History, Bookmarks, Tasks and App Store.
    case internalPage
    /// The draggable and visible split divider line.
    case splitDivider
    /// The diff viewer page (`--cmux-surface-background` in webviews).
    case diff
    /// The markdown page (diff-host S6), with its own override.
    case markdown
    /// The code editor page (diff-host S7), with its own override.
    case editor
}

/// One surface's override: a color, an opacity, or both. Both nil is no
/// override (the window's one backdrop, R48).
public nonisolated struct SurfaceBackground: Hashable, Sendable {
    /// `appearance.surfaces.<surface>.color` (`#RRGGBB[AA]`); nil: the
    /// window's color (the theme background), or the chrome divider's for
    /// the split divider (``SurfaceBackgrounds/dividerLine(base:)``).
    public var color: ThemeRGB?
    /// `appearance.surfaces.<surface>.opacity`, 0...1; nil: the window's
    /// opacity (`appearance.backgroundOpacity`), or the line's own for the
    /// split divider.
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
///   opacity when unset) times the color's own alpha. An owner that paints
///   it over the window's one tint uses ``fill(for:tokens:windowTint:overSheet:)``,
///   which compensates for that tint.
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
    /// - Parameter windowTint: The tint the window shows under the surface
    ///   (``WindowBackdrop/tintOpacity``); over a background picture that is
    ///   the picture's tint, not `background-opacity`. nil reads the tokens'
    ///   own (no picture).
    public func fill(for kind: SurfaceKind, tokens: ThemeTokens, windowTint: Double? = nil) -> ThemeRGB? {
        guard let override = overrides[kind], !override.isEmpty else { return nil }
        let window = windowTint ?? WindowBackdrop(tokens).tintOpacity
        if let color = override.color {
            return color.withAlpha(color.alpha * (override.opacity ?? window))
        }
        let target = override.opacity ?? window
        // Over the tint (alpha `window`), alpha x of the same color covers
        // window + x * (1 - window) = target.
        let alpha = window >= 1 || target <= window ? 0 : (target - window) / (1 - window)
        return tokens.surfaceBackground.withAlpha(alpha)
    }

    /// The split divider's line (`appearance.surfaces.splitDivider`), or nil when it has no override. A line, not a
    /// backdrop: its color (else `base`, the chrome's own divider color) at its opacity times the color's own alpha
    /// (no opacity: the color as it is). Resolved as a backdrop (``fill(for:tokens:windowTint:)``), an opacity alone
    /// painted the window's background color, so any opacity hid the sidebar's edge and every split line (Leo,
    /// 2026-11-19: "why is there no divider showing between my sidebar and the rest of the stuff? and between pane
    /// splits?").
    ///
    /// - Parameter base: The divider's color with no override (`Palette.chromeDivider`).
    public func dividerLine(base: ThemeRGB) -> ThemeRGB? {
        guard let override = overrides[.splitDivider] else { return nil }
        guard let opacity = override.opacity else { return override.color ?? base }
        let color = override.color ?? base.withAlpha(1)
        return color.withAlpha(color.alpha * opacity)
    }

    /// ``fill(for:tokens:windowTint:)`` for an owner that paints it straight over the window's one tint (`sheet` at
    /// `windowTint`, over the picture or the desktop): a color override more opaque than the window is compensated for
    /// the tint under it, so the surface shows that color at exactly its opacity instead of over a second tint (user,
    /// Nov 17: "we need to make sure custom bgs work properly"). Everything else is ``fill(for:tokens:windowTint:)``.
    ///
    /// - Parameter kind: The surface.
    /// - Parameter tokens: The theme tokens of the surface's scope.
    /// - Parameter windowTint: The tint the window shows under the surface; nil reads the tokens' own.
    /// - Parameter sheet: The color of the window's tint under the surface, opaque. Nil (Liquid Glass, which tints
    ///   itself rather than through an alpha layer, or an opaque window) skips the compensation.
    /// - Returns: The color to paint, or nil when the surface has no override.
    public func fill(for kind: SurfaceKind, tokens: ThemeTokens, windowTint: Double? = nil, overSheet sheet: ThemeRGB?) -> ThemeRGB? {
        guard let plain = fill(for: kind, tokens: tokens, windowTint: windowTint) else { return nil }
        guard let sheet, let color = overrides[kind]?.color else { return plain }
        let window = windowTint ?? WindowBackdrop(tokens).tintOpacity
        return compensatedFill(color.withAlpha(1), opacity: plain.alpha, sheet: sheet.withAlpha(1), windowTint: window)
    }

    /// `fill(for:tokens:)` laid over an opaque `base`, for owners that
    /// must paint an opaque color (a docked column hides what scrolls under
    /// it); `base` itself without an override.
    public func opaqueFill(for kind: SurfaceKind, tokens: ThemeTokens, base: ThemeRGB, windowTint: Double? = nil) -> ThemeRGB {
        guard let fill = fill(for: kind, tokens: tokens, windowTint: windowTint) else { return base }
        return fill.composited(over: base.withAlpha(1))
    }

    /// Whether the terminal has an override. Terminals then draw a
    /// transparent default background in every window, so their owner's
    /// fill shows behind the cells (`GhosttyRuntimeSurfacePolicy`).
    public var overridesTerminal: Bool { overrides[.terminal] != nil }
}

/// What a surface paints over the window's one tint (`sheet` at alpha `windowTint`, over the picture or the desktop
/// `P`) so it shows `ground` at `opacity`: `opacity * ground + (1 - opacity) * P`.
///
/// The tint is under every surface, so only a surface more opaque than the window can be exact: alpha
/// `x = (opacity - windowTint) / (1 - windowTint)` keeps `P`'s share at `1 - opacity`, and the color
/// `(opacity * ground - (1 - x) * windowTint * sheet) / x` cancels the tint. Where that color leaves the gamut (a dark
/// ground on a light sheet, a light one on a dark sheet) the alpha rises to the least that keeps every channel in it:
/// `opacity * ground` stays exact and only `P`'s share shrinks, never the hue (Fable 5.2 review). At or below the
/// window's opacity the result is `ground` at `opacity` over the tint, as before (a ground that differs from the
/// sheet cannot show more of `P` than the tint lets through). An opaque window has no `P`: `ground` at `opacity`.
private nonisolated func compensatedFill(_ ground: ThemeRGB, opacity: Double, sheet: ThemeRGB, windowTint: Double) -> ThemeRGB {
    guard windowTint < 1, opacity > windowTint else { return ground.withAlpha(opacity) }
    let pairs = [(ground.red, sheet.red), (ground.green, sheet.green), (ground.blue, sheet.blue)]
    var x = (opacity - windowTint) / (1 - windowTint)
    for (g, s) in pairs {
        let under = windowTint * s
        // F >= 0 needs x >= 1 - opacity*g / under; F <= 1 needs x >= (opacity*g - under) / (1 - under).
        if under > 0 { x = max(x, 1 - opacity * g / under) }
        if under < 1 { x = max(x, (opacity * g - under) / (1 - under)) }
    }
    x = min(x, 1)
    func channel(_ g: Double, _ s: Double) -> Double { min(max((opacity * g - (1 - x) * windowTint * s) / x, 0), 1) }
    return ThemeRGB(red: channel(pairs[0].0, pairs[0].1), green: channel(pairs[1].0, pairs[1].1),
                    blue: channel(pairs[2].0, pairs[2].1), alpha: x)
}
