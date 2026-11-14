public import AppKit

/// The glass levels, native side (schemas/design-scale/design-scale.json `glass`, the entries of
/// `kind: level`; design/glass.md in leo-workspace). Leo, 2026-11-06: "we have, like, a ton of
/// varying glassiness on stuff for some reason". Every glass surface is one level, and the level
/// fixes its tint. The material is the same for each (Liquid Glass on macOS 26, `NSVisualEffectView`
/// before, the opaque popup surface under Reduce Transparency: `OverlayMaterial`). The edge is the
/// role's rim or the one hairline. The web reads the same levels as `--ds-glass-<level>-*`.
/// webviews/test/glass-levels.test.ts holds the names in step with the JSON and fails a native glass
/// view or tint scale built outside the levels.
public nonisolated enum GlassLevel: String, CaseIterable, Sendable {
    /// Glass docked on the window: the tab strip, panels that sit on the chrome, drag ghosts, and
    /// the sidebar's cards and group headers (over the sidebar's own glass).
    case chrome
    /// Floating surfaces over dense content: popovers, hover cards, the palette, find and browser
    /// bars, toasts, dialogs and sheets.
    case popover
    /// Menus. AppKit draws `NSMenu` in its own material; a menu cmux draws is this level.
    case menu
    /// Small glass on one line: tooltips and shortcut hint chips.
    case chip

    /// How much denser than the theme's glass tint (`Palette.glassTint`) the level's tint is: a
    /// multiplier on its alpha. Popovers and menus are a little denser so text over busy content
    /// stays readable (`ChromeTunables.glassOverlayTintStrength` defaults to the same 1.25;
    /// webviews/test/glass-levels.test.ts holds the two equal), chips denser again.
    public var tintStrength: Double {
        switch self {
        case .chrome: 1
        case .popover, .menu: 1.25
        case .chip: 1.5
        }
    }

    /// `base` (the theme's glass tint) at this level's density.
    public func tint(_ base: NSColor) -> NSColor {
        Self.scaled(base, by: tintStrength)
    }

    /// `base` with its alpha scaled by `strength`, clamped to 0...1.
    public static func scaled(_ base: NSColor, by strength: Double) -> NSColor {
        guard strength != 1 else { return base }
        return base.withAlphaComponent(min(max(base.alphaComponent * strength, 0), 1))
    }
}
