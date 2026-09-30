import AppKit
import Testing
@testable import CmuxNextTabs

/// User feedback on nxdog9: the tab x shows only on the hovered tab, and
/// the title never moves or resizes when it appears (the x overlays the
/// title's end, which fades out, as in Chrome and Safari).
@MainActor @Suite struct TabHoverChromeTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView

        init(titles: [String], width: CGFloat = 900) {
            let tabs = titles.enumerated().map { TabItem(id: TabID("t\($0.offset)"), title: $0.element) }
            model = TabStripModel(tabs: tabs, selectedID: TabID("t0"))
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            strip.layoutSubtreeIfNeeded()
            strip.sync(fromModel: true)
        }
    }

    static let longTitle = "A very long tab title that never fits in one tab of the strip"

    @Test func selectedTabHasNoCloseUntilHovered() {
        let h = Harness(titles: ["One", "Two"])
        let selected = h.strip.cells[TabID("t0")]!
        #expect(selected.closeButtonRect == nil)
        #expect(!selected.hasCloseLayers)
        selected.isHovered = true
        #expect(selected.closeButtonRect != nil)
        selected.isHovered = false
        #expect(selected.closeButtonRect == nil)
    }

    @Test func titleKeepsItsFrameWhenTheCloseButtonAppears() {
        let h = Harness(titles: [Self.longTitle, "Two"])
        let cell = h.strip.cells[TabID("t0")]!
        let before = cell.titleLayer.frame
        cell.isHovered = true
        #expect(cell.closeButtonRect != nil)
        #expect(cell.titleLayer.frame == before, "the title does not jump when the x shows")
        cell.isHovered = false
        #expect(cell.titleLayer.frame == before)
    }

    @Test func titleUsesTheFullWidthWhenTheCloseButtonIsHidden() {
        let h = Harness(titles: [Self.longTitle, "Two"])
        let cell = h.strip.cells[TabID("t0")]!
        let metrics = h.strip.metrics
        #expect(cell.titleLayer.frame.maxX == cell.bounds.width - metrics.contentTrailingInset)
    }

    @Test func titleFadesOutBeforeTheOverlayingCloseButton() throws {
        let h = Harness(titles: [Self.longTitle, "Two"])
        let cell = h.strip.cells[TabID("t0")]!
        cell.isHovered = true
        let close = try #require(cell.closeButtonRect)
        let mask = try #require(cell.titleLayer.mask as? CAGradientLayer)
        let locations = try #require(mask.locations).map { CGFloat($0.doubleValue) }
        // Fully clear where the x starts (title coordinates).
        let clearAt = cell.titleLayer.frame.minX + (locations.last ?? 1) * cell.titleLayer.frame.width
        #expect(clearAt <= close.minX + 0.5)
    }

    @Test func shortTitleUnderTheCloseButtonAlsoFades() throws {
        // A title that fits the full width but reaches under the x.
        let h = Harness(titles: ["Short title here", "Two", "Three", "Four", "Five", "Six"], width: 700)
        let cell = h.strip.cells[TabID("t0")]!
        #expect(cell.titleLayer.mask == nil)
        cell.isHovered = true
        let close = try #require(cell.closeButtonRect)
        let textWidth = ceil((cell.displayTitle as NSString).size(withAttributes: [.font: cell.titleFont]).width)
        let textEnd = cell.titleLayer.frame.minX + textWidth
        if textEnd > close.minX {
            #expect(cell.titleLayer.mask != nil)
        } else {
            #expect(cell.titleLayer.mask == nil)
        }
    }
}
