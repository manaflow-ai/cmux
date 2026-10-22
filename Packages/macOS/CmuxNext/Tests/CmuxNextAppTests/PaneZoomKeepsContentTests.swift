import AppKit
@testable import CmuxNextLayout
import Testing

/// A zoom covers the screen's other panes; it does not close them (panes-perf, 2026-10-22: at 30
/// panes a zoom tore down 29 pane controllers when it landed and the unzoom built all 29 again,
/// 35 ms and 120 ms frames on the fleet). Their content views live on, hidden under the zoomed
/// pane, and the unzoom shows the same views again. A pane closed while zoomed still goes.
@MainActor
struct PaneZoomKeepsContentTests {
    final class Panes: LayoutPaneContentProvider {
        var made: [PaneID] = []
        var released: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView {
            made.append(pane)
            return NSView()
        }
        func releaseContentView(_ view: NSView, for pane: PaneID) { released.append(pane) }
    }

    /// p1 p2 / p3 p4.
    static let grid: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                        a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                        b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(reduceMotion: Bool) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(PaneZoomKeepsContentTests.grid))],
                                activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func apply(_ screen: LayoutScreen) {
            model.apply(screens: [screen])
            root.syncWithModel()
            for _ in 0..<240 where root.advanceFrame(1.0 / 120) {}
        }

        func zoom(hiding hidden: [PaneID] = ["p2", "p3", "p4"]) {
            apply(LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")), zoomed: true, zoomHiddenPanes: hidden))
        }

        func unzoom(_ tree: SplitNode = PaneZoomKeepsContentTests.grid) {
            apply(LayoutScreen(id: "s", name: "s", layout: .splits(tree)))
        }

        func shows(_ pane: PaneID) -> Bool {
            guard let host = root.context.hosts[pane], host.superview != nil else { return false }
            return !host.isHiddenOrHasHiddenAncestor
        }
    }

    @Test(arguments: [false, true])
    func aZoomKeepsTheCoveredPanesContentAndTheUnzoomShowsItAgain(reduceMotion: Bool) {
        let screen = Screen(reduceMotion: reduceMotion)
        let views = Dictionary(uniqueKeysWithValues: ["p1", "p2", "p3", "p4"].map { (PaneID($0), screen.root.context.hosts[PaneID($0)]?.content) })
        screen.zoom()
        #expect(screen.provider.released.isEmpty, "a zoom closes no pane's content: released \(screen.provider.released)")
        for pane: PaneID in ["p2", "p3", "p4"] {
            #expect(!screen.shows(pane), "\(pane) is hidden under the zoomed pane")
        }
        #expect(screen.shows("p1"))
        screen.unzoom()
        #expect(screen.provider.made.count == 4, "the unzoom makes no content again: made \(screen.provider.made)")
        for pane: PaneID in ["p1", "p2", "p3", "p4"] {
            #expect(screen.shows(pane), "\(pane) shows after the unzoom")
            #expect(screen.root.context.hosts[pane]?.content === views[pane] ?? nil, "\(pane) shows the same content view")
        }
    }

    @Test func aPaneClosedWhileZoomedIsReleased() {
        let screen = Screen(reduceMotion: false)
        screen.zoom()
        screen.zoom(hiding: ["p2", "p3"])
        #expect(screen.provider.released == ["p4"], "released \(screen.provider.released)")
        screen.unzoom(.split("v", axis: .vertical, ratio: 0.5,
                             a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), b: .leaf("p3")))
        #expect(screen.provider.made.count == 4)
        #expect(screen.shows("p3"))
    }
}
