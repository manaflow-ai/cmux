public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// A tab group chip's look, in the pane's tab strip, the vertical tab list and the saved groups bar: the sidebar group
/// headers' tinted glass with a rim (#36225) on the chip. The chip follows the headers' own choices, so a group reads
/// the same in both places: `sidebar.groupGlass` sets how strongly its color tints the glass,
/// `sidebar.groupHeader.background` (auto, glass, solid) whether it is glass at all, `sidebar.groupPalette` where the
/// color comes from. Solid draws the chip's opaque fill as before (`GroupColor.chipFill`). A group with no color keeps
/// its chip as before too, no fill of its own (cx-rcby: no stored color draws no color). The chip's size never depends
/// on the look: only its fill, rim and ink change.
///
/// ```swift
/// let look = GroupChipGlass.current
/// if let paint = look.paint(tint: group.tint, tokens: tokens, steps: steps, opaque: false) { ... }
/// ```
public nonisolated struct GroupChipGlass: Equatable, Sendable {
    /// How strongly the color tints the glass (`sidebar.groupGlass`).
    public var glass: SidebarGroupGlass
    /// Glass or solid (`sidebar.groupHeader.background`).
    public var background: SidebarGroupBackgroundStyle
    /// Where token colors come from (`sidebar.groupPalette`).
    public var palette: GroupPalette
    /// The desktop picture's color, read so the Wallpaper palette repaints the chips when it changes.
    public var wallpaper: WallpaperTint?

    public init(glass: SidebarGroupGlass, background: SidebarGroupBackgroundStyle, palette: GroupPalette,
                wallpaper: WallpaperTint? = nil) {
        self.glass = glass
        self.background = background
        self.palette = palette
        self.wallpaper = wallpaper
    }

    /// The look the settings ask for now. Read inside an observation, it registers every setting the chip follows.
    @MainActor public static var current: GroupChipGlass {
        let sections = DesignSettings.shared.sidebarSections
        return GroupChipGlass(glass: SidebarGroupGlass.tunable.value, background: sections.groupHeaderBackground,
                              palette: sections.groupPalette, wallpaper: DesignSettings.shared.groupWallpaperTint)
    }

    /// Whether the chip draws as glass: the headers' rule (`SidebarGroupBackgroundStyle.drawsGlass`).
    public var drawsGlass: Bool { background.drawsGlass(appLooksGlassy: glass != .solid) }

    /// The glass paint for a chip colored `tint` over the tab strip's chrome, `steps` (hover, press) laid over it;
    /// nil when the chip is solid or the group has no color.
    @MainActor public func paint(tint: GroupTint, tokens: ThemeTokens, steps: [ThemeRGB] = [], opaque: Bool) -> GroupGlassPaint? {
        guard drawsGlass, !tint.isNone else { return nil }
        return GroupGlassPaint(tint: tint, palette: palette, glass: glass, tokens: tokens, ground: tokens.chromeBackground,
                               steps: steps, opaque: opaque)
    }

    /// The rim's colors: the shared `group` surface role's (`GlassRimView`), top lit, fading to the bottom.
    public static func rim(isDark: Bool) -> (top: NSColor, bottom: NSColor) {
        let look = FloatingGlassStyle.group.look(isDark: isDark)
        return (look.rimTop.nsColor, look.rimBottom.nsColor)
    }
}
