import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A zoomed pane's indicator (Cmd-Shift-Return, Toggle Pane Zoom) sits at the pane's top-right
/// corner, over the content just under the tab bar, not inside the selected tab (user
/// 2026-11-07: "cmd shift enter thing should show up in top right of pane rather than in the tab
/// itself"). It covers neither the tab bar nor its buttons; a click restores the layout.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneZoomIndicatorTests {
    final class Harness {
        let model: TabStripModel
        let pane: PaneContentView
        let content = NSView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []

        init() {
            let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "A tab with a long enough title \($0)") }
            model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
            pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
            pane.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
            window.contentView = pane
            pane.show(content)
            window.orderFrontRegardless()
            settle()
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
        }

        func settle() {
            pane.stripView.syncFromModel()
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }

        /// The pane zooms or restores: the App's `PaneController.apply` sets the model.
        func setZoomed(_ zoomed: Bool) {
            model.zoomsSelected = zoomed
            settle()
        }

        /// The shown view that offers Exit Zoom, anywhere in the pane: not hidden, and neither it nor an ancestor clear.
        var indicator: NSView? {
            func drawn(_ view: NSView) -> Bool {
                var next: NSView? = view
                while let current = next {
                    if current.alphaValue == 0 { return false }
                    next = current.superview
                }
                return true
            }
            func find(_ view: NSView) -> NSView? {
                if !view.isHiddenOrHasHiddenAncestor, drawn(view), view.accessibilityLabel() == Strings.exitZoom,
                   !view.frame.isEmpty { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(pane)
        }

        var zooms: [TabID] { intents.compactMap { if case .toggleZoom(let id) = $0 { id } else { nil } } }

        func closeWindow() { window.closeAfterTest() }
    }

    @Test func noIndicatorWhileThePaneIsNotZoomed() {
        let harness = Harness()
        defer { harness.closeWindow() }
        #expect(harness.indicator == nil)
    }

    /// Zoomed: the indicator shows at the content's top-right, under the tab bar, clear of it and of
    /// its toolbar, and small enough to cover only the corner.
    @Test func theIndicatorSitsAtThePanesTopRightUnderTheTabBar() throws {
        let harness = Harness()
        defer { harness.closeWindow() }
        harness.setZoomed(true)
        let indicator = try #require(harness.indicator, "a zoomed pane shows the Exit Zoom indicator")
        let pane = harness.pane
        let frame = indicator.convert(indicator.bounds, to: pane)
        let host = pane.contentHost.frame
        #expect(frame.maxX <= host.maxX && frame.maxX >= host.maxX - 16, "at the right edge: \(frame) in \(host)")
        #expect(frame.minY >= pane.stripView.frame.maxY, "under the tab bar: \(frame), strip \(pane.stripView.frame)")
        #expect(frame.minY <= pane.stripView.frame.maxY + 16, "at the top: \(frame)")
        #expect(!frame.intersects(pane.stripView.frame))
        if let toolbar = pane.toolbar?.view, !toolbar.isHidden { #expect(!frame.intersects(toolbar.frame)) }
        #expect(frame.width <= 40 && frame.height <= 40, "a corner button, not a bar: \(frame)")
        // The click reaches it: nothing in the pane sits over it.
        let center = pane.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let root = try #require(harness.window.contentView)
        let hit = try #require(root.hitTest(root.superview.map { $0.convert(center, from: nil) } ?? center))
        #expect(hit === indicator || hit.isDescendant(of: indicator), "the indicator takes the click, not \(hit)")
    }

    /// A press restores the layout through Toggle Pane Zoom's one path (`TabStripIntent.toggleZoom`).
    @Test func pressingTheIndicatorRestoresTheLayout() throws {
        let harness = Harness()
        defer { harness.closeWindow() }
        harness.setZoomed(true)
        let indicator = try #require(harness.indicator)
        #expect(indicator.accessibilityPerformPress())
        #expect(harness.zooms == [TabID("tab0")], "\(harness.intents)")
        harness.setZoomed(false)
        #expect(harness.indicator == nil, "the indicator goes with the zoom")
    }

    /// ZOOM VARIANTS 8: a zoom shows and clears the indicator by paint only (HOVER COMMIT's rule). After its first show it
    /// stays in the view tree, unhidden: an `isHidden` flip in the zoom's key turn made AppKit invalidate the window's
    /// cursor rects and drag regions and post a display-link change (0.15-0.35 ms of the turn, ZOOM VARIANTS 7's
    /// profile). A cleared indicator draws nothing, takes no click and is no accessibility element.
    @Test func aZoomShowsAndClearsTheIndicatorByPaintOnly() throws {
        let harness = Harness()
        defer { harness.closeWindow() }
        let view = harness.pane.zoomIndicator
        harness.setZoomed(true)
        try #require(harness.indicator != nil, "a zoomed pane shows the Exit Zoom indicator")
        let frame = view.frame
        harness.setZoomed(false)
        #expect(!view.isHidden, "the unzoom flipped isHidden: AppKit's cursor rects and drag regions in the key turn")
        #expect(view.alphaValue == 0, "the unzoomed pane's indicator still draws")
        #expect(harness.indicator == nil, "the indicator goes with the zoom")
        #expect(view.hitTest(NSPoint(x: frame.midX, y: frame.midY)) == nil, "the cleared indicator takes the click")
        #expect(!view.button.isAccessibilityElement(), "the cleared indicator is still an accessibility element")
        harness.setZoomed(true)
        #expect(!view.isHidden && view.alphaValue == 1 && view.button.isAccessibilityElement(), "the zoom shows it again")
        #expect(view.frame == frame && harness.indicator != nil)
    }

    /// The tab itself draws nothing for a zoom: no badge layer joins the selected tab, and no tab moves.
    @Test func theSelectedTabDrawsNoZoomBadge() throws {
        let harness = Harness()
        defer { harness.closeWindow() }
        let cell = try #require(harness.pane.stripView.cells[TabID("tab0")])
        let layers = cell.layer.sublayers?.count ?? 0
        let frames = harness.pane.stripView.cells.mapValues(\.frame)
        harness.setZoomed(true)
        #expect((cell.layer.sublayers?.count ?? 0) == layers, "the zoom indicator is not in the tab")
        #expect(harness.pane.stripView.cells.mapValues(\.frame) == frames)
    }
}
