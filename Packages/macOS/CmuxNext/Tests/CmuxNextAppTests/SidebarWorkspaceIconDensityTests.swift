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
        let interface = DesignSettings.shared.densityTokens
        DesignSettings.shared.sidebarSections.density = density
        DesignSettings.shared.sidebarSections.textSize = textSize
        DesignSettings.shared.densityTokens = .compact
        defer {
            DesignSettings.shared.sidebarSections.density = saved
            DesignSettings.shared.sidebarSections.textSize = text
            DesignSettings.shared.densityTokens = interface
        }
        let side = SidebarStyle.iconColumnBox
        let emoji = SidebarIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        emoji.configure(icon: .emoji("🚀"))
        emoji.layoutSubtreeIfNeeded()
        let symbol = SidebarIconView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        symbol.configure(icon: .symbol("star.fill", tint: nil))
        symbol.layoutSubtreeIfNeeded()
        let glyph = emoji.subviews.first { $0 is SidebarEmojiGlyphView }?.frame.width ?? 0
        let image = symbol.subviews.compactMap { ($0 as? NSImageView)?.image }.first
        return Drawn(glyph: glyph, symbol: image?.size.height ?? 0)
    }

    @Test func compactKeepsItsSixteenPointGlyph() {
        #expect(Self.drawn(.compact).glyph == 16)
    }

    @Test(arguments: SidebarTextSize.allCases)
    func comfortableDrawsALargerIconThanCompact(_ textSize: SidebarTextSize) {
        let compact = Self.drawn(.compact, textSize), comfortable = Self.drawn(.comfortable, textSize)
        #expect(comfortable.glyph > compact.glyph, "compact \(compact.glyph), comfortable \(comfortable.glyph)")
        #expect(comfortable.symbol > compact.symbol, "compact symbol \(compact.symbol), comfortable \(comfortable.symbol)")
    }
}
