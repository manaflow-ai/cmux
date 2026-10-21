import AppKit
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Lawrence 2026-10-20 (scrawl of a crowded strip of "New Tab" tabs): "by default i should not see
/// layout shift here at all". At the crowded width a hovered tab trades its title for the x, and the
/// favicon was centered again in the room left of the x, so it jumped left about 2 to 4 pt under
/// the pointer and jumped back when the pointer left. Hover (and selection) may show or hide parts,
/// never move the ones that stay: the favicon keeps its x whenever it fits before the close button.
@MainActor @Suite(.serialized) struct TabHoverNoShiftTests {
    private static func cell(width: CGFloat, hovered: Bool, selected: Bool = false) -> TabCell {
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "New Tab", icon: .icon(.browser)))
        cell.isSelected = selected
        cell.frame = CGRect(x: 0, y: 0, width: width, height: 32)
        cell.isHovered = hovered
        cell.layoutLayers()
        return cell
    }

    private static func iconFrame(_ cell: TabCell) -> CGRect {
        let icon = cell.iconLayer
        return CGRect(x: icon.position.x - icon.bounds.width / 2, y: icon.position.y - icon.bounds.height / 2,
                      width: icon.bounds.width, height: icon.bounds.height)
    }

    /// Every width from the strip's crowded minimum up: the favicon is where it was before the hover.
    @Test func hoverNeverMovesTheFavicon() {
        let metrics = TabStripMetrics.standard
        let from = Int(metrics.faviconCloseWidth.rounded(.up))
        for width in from...240 {
            let rest = Self.cell(width: CGFloat(width), hovered: false)
            let hover = Self.cell(width: CGFloat(width), hovered: true)
            #expect(rest.iconLayer.opacity == 1 && hover.iconLayer.opacity == 1, "width \(width): the favicon shows")
            #expect(Self.iconFrame(rest) == Self.iconFrame(hover),
                    "width \(width): hover moved the favicon from \(Self.iconFrame(rest).minX) to \(Self.iconFrame(hover).minX)")
            if let close = hover.closeButtonRect {
                #expect(Self.iconFrame(hover).maxX <= close.minX + 0.5, "width \(width): the x covers the favicon")
            }
        }
    }

    /// The crowded width the capture showed: the x shows on hover and the favicon stays put.
    @Test func crowdedHoveredTabShowsTheXBesideAStillFavicon() {
        let width = TabStripMetrics.standard.faviconCloseWidth
        let rest = Self.cell(width: width, hovered: false)
        let hover = Self.cell(width: width, hovered: true)
        #expect(hover.visibility.showsClose, "a hovered crowded tab shows its x")
        #expect(Self.iconFrame(hover).minX == Self.iconFrame(rest).minX)
    }

    /// The selected tab: hovering it never moves its favicon either.
    @Test func hoverNeverMovesTheSelectedTabsFavicon() {
        let from = Int(TabStripMetrics.standard.faviconCloseWidth.rounded(.up))
        for width in from...240 {
            let rest = Self.cell(width: CGFloat(width), hovered: false, selected: true)
            let hover = Self.cell(width: CGFloat(width), hovered: true, selected: true)
            guard rest.iconLayer.opacity == 1, hover.iconLayer.opacity == 1 else { continue }
            #expect(Self.iconFrame(rest) == Self.iconFrame(hover), "width \(width): hover moved the selected favicon")
        }
    }
}
