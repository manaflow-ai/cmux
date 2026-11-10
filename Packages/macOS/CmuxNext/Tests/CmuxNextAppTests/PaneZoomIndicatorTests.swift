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

        /// The shown view that offers Exit Zoom, anywhere in the pane.
        var indicator: NSView? {
            func find(_ view: NSView) -> NSView? {
                if !view.isHiddenOrHasHiddenAncestor, view.accessibilityLabel() == Strings.exitZoom, !view.frame.isEmpty { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(pane)
        }

        var zooms: [TabID] { intents.compactMap { if case .toggleZoom(let id) = $0 { id } else { nil } } }

        func closeWindow() { window.closeAfterTest() }
    }

    /// A pane with its tab bar's controls (every workspace pane): the indicator sits in the tab bar
    /// immediately left of the pane's "…", on its row and at its size (user 2026-11-09: "the maximize
    /// pane indicator is showing up in wrong place i think we should show it on the left of the 3 dots
    /// indicator"), and nothing of it is left over the content's corner.
    @Test func theIndicatorSitsLeftOfThePanesMoreButton() throws {
        let harness = Harness()
        defer { harness.closeWindow() }
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        harness.pane.toolbar = toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: false, paneKinds: [.terminal])
        harness.settle()
        harness.model.zoomsSelected = true
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        harness.settle()
        let pane = harness.pane
        let indicator = try #require(harness.indicator, "a zoomed pane shows the Exit Zoom indicator")
        let more = toolbar.view.moreButton
        #expect(!more.isHidden)
        let frame = indicator.convert(indicator.bounds, to: pane)
        let moreFrame = more.convert(more.bounds, to: pane)
        let gap = moreFrame.minX - frame.maxX
        #expect(gap >= 0 && gap <= Metrics.space1, "immediately left of \"…\": gap \(gap), \(frame) vs \(moreFrame)")
        #expect(abs(frame.midY - moreFrame.midY) < 0.5, "on \"…\"'s row: \(frame) vs \(moreFrame)")
        #expect(abs(frame.height - moreFrame.height) < 0.5 && abs(frame.width - moreFrame.width) < 0.5, "at \"…\"'s size: \(frame) vs \(moreFrame)")
        #expect(frame.maxY <= pane.contentHost.frame.minY + 0.5, "in the tab bar, not over the content: \(frame)")
        for cell in pane.stripView.cells.values {
            #expect(!frame.intersects(pane.stripView.convert(cell.frame, to: pane)), "clear of every tab")
        }
        #expect(pane.zoomIndicator.isHidden, "no second indicator over the content's corner")
        let center = pane.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let root = try #require(harness.window.contentView)
        let hit = try #require(root.hitTest(root.superview.map { $0.convert(center, from: nil) } ?? center))
        #expect(hit === indicator || hit.isDescendant(of: indicator), "the indicator takes the click, not \(hit)")
        #expect(indicator.accessibilityPerformPress())
        #expect(harness.zooms == [TabID("tab0")], "\(harness.intents)")
    }

    @Test func noIndicatorWhileThePaneIsNotZoomed() {
        let harness = Harness()
        defer { harness.closeWindow() }
        #expect(harness.indicator == nil)
    }

    /// Zoomed in a pane with no tab bar controls: the indicator shows at the content's top-right, under
    /// the tab bar, clear of it, and small enough to cover only the corner.
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
