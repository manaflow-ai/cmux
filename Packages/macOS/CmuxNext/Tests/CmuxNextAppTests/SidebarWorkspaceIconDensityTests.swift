import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A workspace icon follows the sidebar density (Leo 2026-11-03: "generally we can have stuff more dynamically sized
/// for compact/etc rn i think it's just a one size for these workspace icons"): its glyph fills the density's icon
/// column, so comfortable draws it larger than compact, and compact keeps its old size.
@MainActor @Suite(.serialized) struct SidebarWorkspaceIconDensityTests {
    private struct Drawn: Equatable {
        var glyph: CGFloat
        var symbol: CGFloat
    }

    private static func drawn(_ density: SidebarDensity, _ textSize: SidebarTextSize = .standard) -> Drawn {
        let saved = DesignSettings.shared.sidebarSections.density, text = DesignSettings.shared.sidebarSections.textSize
        DesignSettings.shared.sidebarSections.density = density
        DesignSettings.shared.sidebarSections.textSize = textSize
        defer {
            DesignSettings.shared.sidebarSections.density = saved
            DesignSettings.shared.sidebarSections.textSize = text
        }
        let side = SidebarStyle.iconColumnBox
        let emoji = SidebarIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        emoji.configure(icon: .emoji("🚀", nil))
        emoji.layoutSubtreeIfNeeded()
        let symbol = SidebarIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        symbol.configure(icon: .symbol("star.fill", tint: nil))
        symbol.layoutSubtreeIfNeeded()
        let glyph = emoji.subviews.first { $0 is SidebarEmojiGlyphView }?.frame.width ?? 0
        let image = symbol.subviews.compactMap { ($0 as? NSImageView)?.image }.first
        return Drawn(glyph: glyph, symbol: image?.size.height ?? 0)
    }

    @Test func compactKeepsItsSixteenPointGlyph() {
        let compact = Self.drawn(.compact)
        #expect(compact.glyph == SidebarStyle.iconBox, "compact glyph \(compact.glyph)")
    }

    @Test(arguments: SidebarTextSize.allCases)
    func comfortableDrawsALargerIconThanCompact(_ textSize: SidebarTextSize) {
        let compact = Self.drawn(.compact, textSize), comfortable = Self.drawn(.comfortable, textSize)
        #expect(comfortable.glyph > compact.glyph, "compact \(compact.glyph), comfortable \(comfortable.glyph)")
        #expect(comfortable.symbol > compact.symbol, "compact symbol \(compact.symbol), comfortable \(comfortable.symbol)")
    }

    /// The glyph never outgrows the icon column it sits in, so the title keeps its place.
    @Test(arguments: [SidebarDensity.compact, .comfortable, .expanded])
    func theGlyphFillsItsColumnAndNoMore(_ density: SidebarDensity) {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        #expect(SidebarStyle.workspaceGlyphSide == SidebarStyle.iconColumnBox)
        #expect(SidebarStyle.workspaceGlyphScale >= 1)
    }
}
