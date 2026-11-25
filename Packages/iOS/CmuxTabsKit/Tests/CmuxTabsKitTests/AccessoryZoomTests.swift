@testable import CmuxTabsKit
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing

/// The accessory row (composer, key row) is part of the page <-> grid zoom:
/// it never disappears in one frame when the tabs button is tapped, it moves
/// with the page, and a reversal mid-flight does not jump it (Leo,
/// 2026-11-22: "the layout shift when i go from terminal to that view via
/// that button is crazy because it has to tuck away the composer area").
struct AccessoryZoomTests {
    private let path = ZoomRectPath(full: CGRect(x: 0, y: 0, width: 402, height: 874),
                                    card: CGRect(x: 20, y: 140, width: 174, height: 300))

    private func run(_ s: inout TabZoomState, frames: Int) {
        for _ in 0..<frames { s.step(1.0 / 120) }
    }

    /// The layer's top-left and size as drawn, to compare frames.
    private func drawn(_ a: AccessoryZoom) -> CGRect {
        CGRect(x: a.origin.x, y: a.origin.y, width: path.full.width * a.scale, height: path.full.height * a.scale)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// The tap's first frame: the zoom has started (progress 0), and the row
    /// is still there, drawn exactly as on the page. Before, it was removed
    /// in that frame and the page jumped before the zoom moved.
    @Test func tabsButtonKeepsTheRowOnTheFirstFrame() {
        var s = TabZoomState()
        let onPage = AccessoryZoom.presentation(s, path: path)
        s.go(toOverview: true)
        #expect(s.phase == .animating && s.progress == 0)
        let first = AccessoryZoom.presentation(s, path: path)
        #expect(first.opacity == onPage.opacity)
        #expect(first.scale == onPage.scale && first.origin == onPage.origin)
        #expect(!first.interactive)
    }

    /// Along the whole way, in both directions, opacity and frame change
    /// smoothly with progress: no step anywhere, including at 0.
    @Test func continuousInProgressBothDirections() {
        for phase in [TabZoomState.Phase.animating, .interactive] {
            var previous: AccessoryZoom?
            for i in 0...200 {
                let p = Double(i) / 200
                let a = AccessoryZoom.presentation(phase: phase, progress: p, offset: .zero, path: path)
                if let previous {
                    #expect(abs(a.opacity - previous.opacity) <= 0.011, "opacity step at \(p)")
                    #expect(distance(drawn(a), drawn(previous)) <= 4.5, "frame step at \(p)")
                }
                previous = a
            }
        }
        // The ends meet the settled states.
        #expect(AccessoryZoom.presentation(phase: .animating, progress: 0, offset: .zero, path: path).opacity == 1)
        #expect(AccessoryZoom.presentation(phase: .animating, progress: 1, offset: .zero, path: path).opacity == 0)
        #expect(AccessoryZoom.presentation(phase: .overview, progress: 1, offset: .zero, path: path).opacity == 0)
    }

    /// It rides the page's rect: the full-screen layer maps onto the zoom's
    /// rect exactly as the page does.
    @Test func ridesThePageRect() {
        for p in [0.0, 0.1, 0.25, 0.4] {
            let a = AccessoryZoom.presentation(phase: .animating, progress: p, offset: CGVector(dx: 6, dy: -9), path: path)
            let rect = path.rect(progress: p, offset: CGVector(dx: 6, dy: -9))
            #expect(abs(drawn(a).minX - rect.minX) < 0.001 && abs(drawn(a).minY - rect.minY) < 0.001)
            #expect(abs(drawn(a).width - rect.width) < 0.001)
        }
    }

    /// Tabs button, then the tabs button again mid-flight (or Done): the row
    /// follows the zoom back from where it is, frame by frame, moving exactly
    /// as the page does (the zoom retargets from where it is).
    @Test func reversalMidFlightDoesNotJump() {
        var s = TabZoomState()
        s.go(toOverview: true)
        run(&s, frames: 9)
        let before = AccessoryZoom.presentation(s, path: path)
        #expect(before.opacity > 0 && before.opacity < 1)
        var previous = before
        var previousPage = path.rect(progress: s.progress, offset: s.offset)
        s.go(toOverview: false)
        for _ in 0..<120 {
            let a = AccessoryZoom.presentation(s, path: path)
            let page = path.rect(progress: s.progress, offset: s.offset)
            #expect(abs(a.opacity - previous.opacity) < 0.2)
            #expect(distance(drawn(a), drawn(previous)) <= distance(page, previousPage) + 0.001)
            previous = a
            previousPage = page
            s.step(1.0 / 120)
        }
        #expect(s.phase == .page)
        #expect(AccessoryZoom.presentation(s, path: path) == .identity)
    }

    /// From the grid back to a page it comes in with the zoom instead of
    /// appearing when the zoom settles.
    @Test func doneBringsTheRowInAlongTheWay() {
        var s = TabZoomState(overview: true)
        let grid = AccessoryZoom.presentation(s, path: path)
        #expect(grid.opacity == 0 && !grid.interactive && !grid.accessible)
        s.go(toOverview: false)
        var opacities: [Double] = []
        while s.phase == .animating {
            s.step(1.0 / 120)
            opacities.append(AccessoryZoom.presentation(s, path: path).opacity)
        }
        #expect(opacities.contains { $0 > 0.2 && $0 < 0.9 }, "fades in during the zoom: \(opacities)")
        #expect(AccessoryZoom.presentation(s, path: path) == .identity)
    }
}
