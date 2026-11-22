import CmuxNextDesign
import QuartzCore

/// The `tab.close` theme slot (schemas/theme/slots.json): the glyph a pane tab's close button draws.
/// The variant is the theme file's `slots["tab.close"]` as the daemon resolved it
/// (`theme.slots.resolve`, ``DesignSettings/themeSlots``); none, or one this build does not ship,
/// draws ``default``, the x the tab drew before slots. The square, its place, fill, colors, fade
/// and click stay ``TabCell``'s.
enum TabCloseSlot: String, CaseIterable, Sendable {
    /// Two round-capped strokes corner to corner across the glyph box (``TabCell/closeGlyphPath(in:)``).
    case `default`

    /// The slot's id in schemas/theme/slots.json and in a theme file's `slots`.
    static let id = "tab.close"

    /// The variant `slots` (slot id to variant id) picks; ``default`` when it picks none this build has.
    static func variant(in slots: [String: String]) -> TabCloseSlot {
        slots[id].flatMap(TabCloseSlot.init(rawValue:)) ?? .default
    }

    /// The variant the active theme file picks.
    @MainActor static var current: TabCloseSlot { variant(in: DesignSettings.shared.themeSlots) }

    /// The glyph's path inside `glyph` (the glyph layer's own box), stroked by the host.
    @MainActor func glyphPath(in glyph: CGRect) -> CGPath {
        switch self {
        case .default: TabCell.closeGlyphPath(in: glyph)
        }
    }
}
