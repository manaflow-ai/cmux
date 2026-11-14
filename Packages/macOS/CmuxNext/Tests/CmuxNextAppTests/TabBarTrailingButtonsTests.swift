import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-11-07, a shot of a pane tab bar's trailing `+ ⌄ ⋮`: "i still dont like these UIs". The + drew a bare
/// stroke while the ⌄ beside it drew an SF Symbol on a square grey block and the ⋮ a pack glyph on a rounded plate: three
/// looks, and a block where the rest of the bar has none. And, beside Chrome: "Austin's…(7 days)", a "…" in the middle
/// of a tab title, where Chrome runs the title to the tab's end and fades it.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabBarTrailingButtonsTests {
    private struct Harness {
        let window: NSWindow
        let strip: TabStripView

        init(titles: [String] = ["zsh", "Austin's Weekly Planning Review (7 days)"], width: CGFloat = 520) {
            let tabs = titles.enumerated().map { TabItem(id: TabID("tab\($0.offset)"), title: $0.element) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab0")))
            strip.dragsWindowFromEmptySpace = false
            strip.showsNewTabMenuButton = true
            strip.frame = NSRect(x: 0, y: 0, width: width, height: TabStripView.preferredHeight)
            window.contentView = strip
            strip.layoutSubtreeIfNeeded()
            strip.layoutSubtreeIfNeeded()
        }
    }

    /// Every layer under `root` (itself included) that paints a visible fill.
    private func filledLayers(_ root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func visit(_ layer: CALayer) {
            if !layer.isHidden, let color = layer.backgroundColor, color.alpha > 0.001 { found.append(layer) }
            layer.sublayers?.forEach(visit)
        }
        visit(root)
        return found
    }

    private func shapeLayers(_ root: CALayer) -> [CAShapeLayer] {
        var found: [CAShapeLayer] = []
        func visit(_ layer: CALayer) {
            if let shape = layer as? CAShapeLayer, !shape.isHidden, shape.path != nil { found.append(shape) }
            layer.sublayers?.forEach(visit)
        }
        visit(root)
        return found
    }

    @Test func thePaneTypeChevronDrawsNoBlockWhileItsMenuIsOpen() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let chooser = harness.strip.newTabMenuButton
        #expect(!chooser.isHidden, "the pane asks for its type chooser")
        chooser.isHighlighted = true // what the strip sets while the chooser's menu is open
        chooser.layoutSubtreeIfNeeded()
        let layer = try #require(chooser.layer)
        let blocks = filledLayers(layer).filter { abs($0.bounds.width - $0.bounds.height) > 0.5 || $0.cornerRadius < $0.bounds.width / 2 - 0.5 }
        #expect(blocks.isEmpty, "the ⌄ paints a rectangular block: \(blocks.map { "\($0.bounds.size) r\($0.cornerRadius)" })")
    }

    @Test func thePaneMoreDrawsNoPlateWhileItsMenuIsOpen() throws {
        let toolbar = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 80, height: TabStripView.preferredHeight))
        toolbar.show(more: true, lit: false)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.moreButton.showsMenu = true
        toolbar.moreButton.updateLayer()
        let layer = try #require(toolbar.moreButton.layer)
        let blocks = filledLayers(layer).filter { abs($0.bounds.width - $0.bounds.height) > 0.5 || $0.cornerRadius < $0.bounds.width / 2 - 0.5 }
        #expect(blocks.isEmpty, "the ⋮ paints a plate: \(blocks.map { "\($0.bounds.size) r\($0.cornerRadius)" })")
    }

    @Test func theChevronIsDrawnAtThePlusStrokeWeight() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let plus = try #require(harness.strip.newTabButton.layer.map(shapeLayers)?.first, "the + draws a stroke")
        let chevron = try #require(harness.strip.newTabMenuButton.layer.map(shapeLayers)?.first, "the ⌄ draws a stroke beside the +")
        #expect(abs(chevron.lineWidth - plus.lineWidth) < 0.01, "⌄ \(chevron.lineWidth) pt vs + \(plus.lineWidth) pt")
        #expect(chevron.lineCap == plus.lineCap)
        // Centered on the same line as the +.
        let plusBox = try #require(plus.path?.boundingBox), chevronBox = try #require(chevron.path?.boundingBox)
        let plusMid = harness.strip.newTabButton.convert(CGPoint(x: 0, y: plusBox.midY), to: harness.strip).y
        let chevronMid = harness.strip.newTabMenuButton.convert(CGPoint(x: 0, y: chevronBox.midY), to: harness.strip).y
        #expect(abs(plusMid - chevronMid) <= 0.5, "⌄ center y \(chevronMid) vs + \(plusMid)")
    }

    @Test(arguments: [300, 200])
    func aLongTitleIsNeverTruncatedWithAnEllipsis(width: Int) throws {
        let harness = Harness(width: CGFloat(width))
        defer { harness.window.closeAfterTest() }
        let cell = try #require(harness.strip.cells[TabID("tab1")])
        guard cell.visibility.showsTitle else { return }
        #expect(cell.titleLayer.truncation == nil, "a \(cell.frame.width) pt tab truncates its title (\(String(describing: cell.titleLayer.truncation)))")
        #expect(cell.titleLayer.mask != nil, "the clipped title fades out at the tab's trailing end")
    }

    @Test func aTabTitleIsChromesTwelvePoints() {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        for cell in harness.strip.cells.values { #expect(cell.titleFont.pointSize == 12 * Typography.userScale) }
    }
}
