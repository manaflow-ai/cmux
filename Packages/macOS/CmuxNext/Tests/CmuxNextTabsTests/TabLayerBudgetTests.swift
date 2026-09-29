import AppKit
import Testing
@testable import CmuxNextTabs

/// Tabs are CALayers (architecture.md 3); rarely needed parts (spinner,
/// badge, close button) must not exist until a tab needs them.
@MainActor @Suite struct TabLayerBudgetTests {
    final class Harness {
        let window: NSWindow
        let model: TabStripModel
        let strip: TabStripView

        init(count: Int, busy: Set<Int> = [], unread: Set<Int> = []) {
            let tabs = (0..<count).map { i in
                TabItem(id: TabID("t\(i)"), title: "Tab \(i)", isUnread: unread.contains(i), isBusy: busy.contains(i))
            }
            model = TabStripModel(tabs: tabs, selectedID: TabID("t0"))
            strip = TabStripView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            strip.frame = NSRect(x: 0, y: 0, width: 1400, height: TabStripView.preferredHeight)
            window.contentView!.addSubview(strip)
            strip.layoutSubtreeIfNeeded()
            strip.sync(fromModel: true)
        }

        /// Every layer in the strip: each view's own layer tree, walking the
        /// view hierarchy (AppKit attaches subview layers lazily).
        var totalLayers: Int { Self.count(view: strip) }

        static func count(view: NSView) -> Int {
            let subviewLayers = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
            func walk(_ layer: CALayer) -> Int {
                guard !subviewLayers.contains(ObjectIdentifier(layer)) else { return 0 }
                return 1 + (layer.sublayers ?? []).reduce(0) { $0 + walk($1) } + (layer.mask.map(walk) ?? 0)
            }
            return (view.layer.map(walk) ?? 0) + view.subviews.reduce(0) { $0 + count(view: $1) }
        }

        var tabLayers: Int { strip.cells.values.reduce(0) { $0 + Self.count($1.layer) } }

        static func count(_ layer: CALayer) -> Int {
            1 + (layer.sublayers ?? []).reduce(0) { $0 + count($1) } + (layer.mask.map(count) ?? 0)
        }
    }

    @Test func hundredIdleTabsStayWithinFiveLayersEach() {
        let h = Harness(count: 100)
        print("tab-layer-budget: 100 tabs -> \(h.totalLayers) layers in strip, \(h.tabLayers) in tab cells")
        // root, background, separator, icon, title per tab; the selected tab
        // adds its close button (2 layers).
        #expect(h.tabLayers <= 100 * 5 + 2)
    }

    @Test func spinnerAndBadgeLayersExistOnlyWhileNeeded() {
        let h = Harness(count: 3)
        let cell = h.strip.cells[TabID("t1")]!
        let idle = Harness.count(cell.layer)
        h.model.tabs[1].isBusy = true
        h.model.tabs[1].isUnread = true
        h.strip.sync(fromModel: true)
        #expect(Harness.count(cell.layer) == idle + 2)
        h.model.tabs[1].isBusy = false
        h.model.tabs[1].isUnread = false
        h.strip.sync(fromModel: true)
        #expect(Harness.count(cell.layer) == idle)
    }
}
