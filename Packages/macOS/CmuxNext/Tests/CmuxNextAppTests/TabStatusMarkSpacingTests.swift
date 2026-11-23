import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Leo 2026-10-22 (ask-a8b97f1201): "the tab unread + simultaneous ongoing thing feels weird idk if there is a way
/// to combine + the spacing is off". The tab's trailing mark (the spinner, the unread dot) sat 13 pt from the pill's
/// end while the icon sits 16 pt from its start, so the spinner's ink hugged the trailing edge (8 pt against the
/// icon's 11). The mark now mirrors the icon: as far from the trailing edge as the icon from the leading one.
@MainActor @Suite(.serialized) struct TabStatusMarkSpacingTests {
    private static func cell(busy: Bool, unread: Bool = false, hovered: Bool = false,
                             placement: TabStatusMarkPlacement? = nil) -> TabCell {
        var item = TabItem(id: TabID("spacing"), title: "A page title long enough to run past the tab's end",
                           icon: .icon(.browser), isUnread: unread, isBusy: busy)
        if busy { item.indicator = .busy(progress: nil) }
        let cell = TabCell(item: item)
        if let placement {
            var metrics = cell.metrics
            metrics.statusMarkPlacement = placement
            cell.metrics = metrics
        }
        cell.scale = 2
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        cell.isHovered = hovered
        cell.layoutLayers()
        return cell
    }

    /// The icon's center from the pill's leading edge, and a mark's center from its trailing edge.
    private static func insets(_ cell: TabCell, mark: CGRect) -> (icon: CGFloat, mark: CGFloat) {
        let pill = cell.backgroundLayer.frame
        return (cell.iconLayer.position.x - pill.minX, pill.maxX - mark.midX)
    }

    @Test func theDefaultSpinnerMirrorsTheIcon() throws {
        let cell = Self.cell(busy: true)
        let spinner = try #require(cell.spinnerLayer?.frame, "a busy tab shows no spinner")
        let (icon, mark) = Self.insets(cell, mark: spinner)
        #expect(abs(icon - mark) <= 0.5, "the spinner sits \(mark) pt from the trailing edge, the icon \(icon) pt from the leading one")
    }

    @Test func theDefaultUnreadDotMirrorsTheIcon() throws {
        let cell = Self.cell(busy: false, unread: true)
        let dot = try #require(cell.badgeLayer?.frame, "an unread tab shows no dot")
        let (icon, mark) = Self.insets(cell, mark: dot)
        #expect(abs(icon - mark) <= 0.5, "the dot sits \(mark) pt from the trailing edge, the icon \(icon) pt from the leading one")
    }

    /// Hovering swaps the mark for the x: the title's end holds under every placement.
    @Test(arguments: TabStatusMarkPlacement.allCases)
    func hoveringKeepsTheTitleEnd(placement: TabStatusMarkPlacement) throws {
        let cell = Self.cell(busy: true, placement: placement)
        let rest = try #require(cell.titleFade.geometry?.visibleWidth)
        cell.isHovered = true
        cell.layoutLayers()
        #expect(cell.titleFade.geometry?.visibleWidth == rest, "\(placement): the title's visible width moved on hover")
    }

    /// The old placement, kept behind the Debug setting: the mark centered in the x's slot.
    @Test func theCloseSlotPlacementCentersTheMarkOnTheX() throws {
        let cell = Self.cell(busy: true, placement: .closeSlot)
        let spinner = try #require(cell.spinnerLayer?.frame)
        let m = cell.metrics
        let pill = cell.backgroundLayer.frame
        #expect(abs((pill.maxX - spinner.midX) - (m.contentTrailingInset + m.closeButtonSize / 2)) <= 0.5)
    }

    /// Under `mirrorAll` the hovered x moves into the mirrored slot. The x's one origin
    /// (`TabChromeVisibility.closeButtonOriginX`), which rapid close's hit target and the accessibility
    /// child read before hover, lands where the cell draws it.
    @Test func theMirroredXIsWhereItsTargetsAre() throws {
        let hovered = Self.cell(busy: true, hovered: true, placement: .mirrorAll)
        let drawn = try #require(hovered.closeButtonRect, "the hovered tab draws no x")
        let m = hovered.metrics
        let form = TabChromeVisibility.resolve(
            width: hovered.bounds.width, isPinned: false, isSelected: false, isHovered: true,
            hasStatus: true, style: hovered.style, metrics: m)
        // The cell lays out in its pill (`TabStripMetrics.pillFrame`), as the hit target does.
        let pill = hovered.backgroundLayer.frame
        let origin = try #require(form.closeButtonOriginX(pillWidth: pill.width, metrics: m))
        #expect(abs(origin - drawn.minX) <= 0.5, "the x's target starts at \(origin), the x draws at \(drawn.minX)")

        let rest = Self.cell(busy: true, placement: .mirrorAll)
        let axFrame = rest.accessibility.closeButton.accessibilityFrameInParentSpace()
        #expect(abs(axFrame.midX - drawn.midX) <= 0.5, "the accessibility x centers at \(axFrame.midX), the x draws at \(drawn.midX)")
    }
}
