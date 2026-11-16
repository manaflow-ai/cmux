import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-11-12: "when i do cmd shift enter, i sometimes still see the separation border overlayed on top of
/// what i see". A zoom (Cmd-Shift-Enter) and an unzoom draw nothing of a split over the pane that zooms: no divider
/// line above it in the window, no line hole cut through its Chromium page (`LayoutRootView.interactiveOverlayRects`,
/// the rects pages leave uncovered so the native line shows through), and no ring, border or dim of a pane it covers
/// over it. Every display frame of every motion is checked (the test is the clock, 120 Hz), for each pane of layouts
/// where a pane is at a split's end and where it sits in the middle of a longer line (a middle row or column), and
/// for a zoom interrupted by an unzoom and the reverse.
@MainActor
@Suite(.closesItsWindows)
struct ZoomShowsNoDividerOverPaneTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120

    /// p1 p2 / p3 p4.
    nonisolated static let grid2: SplitNode = .split("v", axis: .vertical, ratio: 0.5,
                                         a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                                         b: .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))
    /// p1 | (p2 / p3 / p4): the middle rows' pane sits in the middle of the long vertical line beside it.
    nonisolated static let leftAndThreeRows: SplitNode = .split("c", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                                    b: .split("r1", axis: .vertical, ratio: 1.0 / 3, a: .leaf("p2"),
                                                              b: .split("r2", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))))
    /// (p1 | p2 | p3) over p4: the middle column's pane sits in the middle of the long horizontal line under it.
    nonisolated static let threeColumnsOverOne: SplitNode = .split("h", axis: .vertical, ratio: 0.5,
                                                       a: .split("c1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                 b: .split("c2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))),
                                                       b: .leaf("p4"))

    nonisolated static let layouts: [(String, SplitNode)] = [("grid2", grid2), ("leftAndThreeRows", leftAndThreeRows),
                                                 ("threeColumnsOverOne", threeColumnsOverOne)]

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let tree: SplitNode

        init(_ tree: SplitNode) {
            self.tree = tree
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            land()
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func zoom(_ pane: PaneID) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf(pane)), zoomed: true)])
            root.syncWithModel()
        }

        func unzoom() {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        func land(check: ((Int) -> Void)? = nil) {
            var frame = 0
            while root.advanceFrame(ZoomShowsNoDividerOverPaneTests.dt), frame < 600 {
                frame += 1
                check?(frame)
            }
            check?(frame + 1)
        }

        func steps(_ count: Int, check: (Int) -> Void) {
            for frame in 1...count {
                root.advanceFrame(ZoomShowsNoDividerOverPaneTests.dt)
                check(frame)
            }
        }

        /// The divider lines the overlay reports now (pages cut holes for them), in the screen's coordinates.
        var lineHoles: [CGRect] { root.interactiveOverlayRects.map { screen.convert($0, from: root) } }

        /// What shows over `pane`'s host (screen coordinates, its inside: one point in from each edge) in this frame:
        /// each line hole there, each divider line drawn above it in the window, and each other pane's overlay
        /// (ring, border, dim) not masked out there. Empty when nothing shows over it.
        func drawnOver(_ pane: PaneID) -> [String] {
            guard let host = root.context.hosts[pane], host.superview === screen, !host.isHidden else { return [] }
            let inside = host.frame.insetBy(dx: 1, dy: 1)
            guard inside.width > 0, inside.height > 0 else { return [] }
            var found: [String] = []
            for hole in lineHoles where hole.intersection(inside).width > 0.5 && hole.intersection(inside).height > 0.5 {
                found.append("line hole \(hole)")
            }
            let hostIndex = screen.subviews.firstIndex { $0 === host } ?? 0
            for (index, view) in screen.subviews.enumerated() where index > hostIndex {
                guard let divider = view as? DividerHandleView, !divider.isHidden, divider.alphaValue > 0.01, divider.isLineVisible else { continue }
                let line = divider.lineFrameInSuperview.intersection(inside)
                if line.width > 0.5, line.height > 0.5 { found.append("divider \(divider.kind) above it at \(line)") }
            }
            for (other, otherHost) in root.context.hosts where other != pane {
                let chrome = otherHost.chrome
                guard chrome.superview === root.overlayPlane, !chrome.isHidden, chrome.alphaValue > 0.01,
                      chrome.layer?.sublayers?.contains(where: { !$0.isHidden && $0.opacity > 0.001 }) == true else { continue }
                let shared = root.convert(inside, from: screen).intersection(chrome.frame)
                guard shared.width > 0.5, shared.height > 0.5 else { continue }
                let mask = (chrome.layer?.mask as? CAShapeLayer)?.path
                let local = shared.offsetBy(dx: -chrome.frame.minX, dy: -chrome.frame.minY)
                let probes = [CGPoint(x: local.midX, y: local.midY), CGPoint(x: local.minX + 1, y: local.minY + 1),
                              CGPoint(x: local.maxX - 1, y: local.maxY - 1)]
                if mask == nil || probes.contains(where: { mask!.contains($0) }) {
                    found.append("\(other.rawValue)'s overlay over it at \(shared)")
                }
            }
            return found
        }
    }

    /// The pane that owns the motion now, else the zoomed one.
    static func front(_ screen: Screen, zoomed: PaneID) -> PaneID { screen.screen.zoomMotion.pane ?? zoomed }

    @Test(arguments: layouts.flatMap { name, tree in tree.panes.map { (name, tree, $0) } })
    func aZoomAndAnUnzoomDrawNoSplitOverThePane(layout: String, tree: SplitNode, pane: PaneID) {
        let screen = Screen(tree)
        defer { screen.window.closeAfterTest() }
        #expect(!screen.lineHoles.isEmpty, "\(layout): no divider line at rest: the check would see nothing")
        var failures: [String] = []
        func check(_ phase: String) -> (Int) -> Void {
            { frame in
                let over = screen.drawnOver(Self.front(screen, zoomed: pane))
                if !over.isEmpty { failures.append("\(layout) \(pane.rawValue) \(phase) frame \(frame): \(over.joined(separator: "; "))") }
            }
        }
        screen.zoom(pane)
        check("zoom")(0)
        screen.land(check: check("zoom"))
        #expect(screen.lineHoles.isEmpty, "\(layout) \(pane.rawValue): zoomed, a line hole is left: \(screen.lineHoles)")
        screen.unzoom()
        check("unzoom")(0)
        screen.land(check: check("unzoom"))
        // Interrupted: an unzoom a few frames into the zoom, and a zoom a few frames into the unzoom.
        screen.zoom(pane)
        screen.steps(4, check: check("zoom before interrupt"))
        screen.unzoom()
        screen.steps(4, check: check("unzoom mid-zoom"))
        screen.zoom(pane)
        screen.land(check: check("zoom mid-unzoom"))
        #expect(screen.lineHoles.isEmpty, "\(layout) \(pane.rawValue): zoomed again, a line hole is left: \(screen.lineHoles)")
        screen.unzoom()
        screen.land(check: check("last unzoom"))
        #expect(failures.isEmpty, "\(failures.count) frames drew a split over the zooming pane; first: \(failures.prefix(4).joined(separator: "\n"))")
    }
}
