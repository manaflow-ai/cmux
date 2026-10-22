import AppKit
@testable import CmuxNextLayout
import Testing

/// While a split, close or zoom springs, the divider hit areas and line rects change on every
/// display frame. Each report moves the window's divider click-catcher panels (window server
/// reordering) and re-places every Chromium page: at 30 panes it was the layout's heaviest path on
/// the fleet (panes-perf 2026-10-22). The window hears them once, when the panes land, with the
/// rects at rest.
@MainActor
struct PaneMotionOverlayReportTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class HostWindow: NSWindow, OverlayPlaneHosting {
        var reports: [[LayoutMouseArea]] = []
        weak var root: LayoutRootView?
        func adoptPlane(_ plane: OverlayPlane) {}
        func releasePlane(_ plane: OverlayPlane) {}
        func interactiveOverlayRectsDidChange(_ plane: OverlayPlane) { reports.append(root?.dividerMouseAreas ?? []) }
        func planeDidLayout(_ plane: OverlayPlane) {}
        func paneShapesDidChange(_ plane: OverlayPlane) {}
    }

    @Test func aSplitSpringReportsItsDividerAreasOnceWhenItLands() throws {
        let two: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(two))], activeScreenID: "s", focusedPane: "p1")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                                backing: .buffered, defer: true)
        window.root = root
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for _ in 0..<240 where root.advanceFrame(1.0 / 120) {}
        let before = window.reports.count

        let three: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                      b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(three))])
        root.syncWithModel()
        var frames = 0
        while root.advanceFrame(1.0 / 120), frames < 240 { frames += 1 }
        let during = window.reports.count - before
        #expect(frames > 5, "the split sprang: \(frames) frames")
        #expect(during <= 2, "divider areas reported \(during) times over \(frames) frames")
        let last = try #require(window.reports.last)
        #expect(last == root.dividerMouseAreas, "the last report is the layout at rest")
        #expect(last.count == 2, "both dividers: \(last)")
    }
}
