#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import Testing

/// ``WindowViewGeometry``: what a launch recording counts as moved between two frames.
@MainActor
@Suite struct WindowViewGeometryTests {
    private func tree() -> (root: NSView, sidebar: NSView, pane: NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let pane = NSView(frame: NSRect(x: 240, y: 0, width: 560, height: 600))
        root.addSubview(sidebar)
        root.addSubview(pane)
        return (root, sidebar, pane)
    }

    @Test func aStillTreeChangesNothing() {
        let views = tree()
        let first = WindowViewGeometry(root: views.root)
        #expect(first.count == 3)
        #expect(WindowViewGeometry(root: views.root).changes(since: first).total == 0)
    }

    @Test func aResizedSidebarAndTheMovedPaneCount() {
        let views = tree()
        let first = WindowViewGeometry(root: views.root)
        views.sidebar.frame.size.width = 312
        views.pane.frame = NSRect(x: 312, y: 0, width: 488, height: 600)
        let change = WindowViewGeometry(root: views.root).changes(since: first)
        #expect(change.total == 2)
        #expect(change.lines.contains("NSView moved 0,0,240,600 -> 0,0,312,600"))
    }

    @Test func aViewShownOrAddedLaterCountsAndAHiddenOneDoesNot() {
        let views = tree()
        let hidden = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        hidden.isHidden = true
        views.pane.addSubview(hidden)
        let first = WindowViewGeometry(root: views.root)
        hidden.frame.origin.x = 40 // not drawn before or after: no change
        #expect(WindowViewGeometry(root: views.root).changes(since: first).total == 0)
        hidden.isHidden = false
        views.sidebar.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30)))
        let change = WindowViewGeometry(root: views.root).changes(since: first)
        #expect(change.total == 2)
        #expect(change.lines.contains { $0.hasSuffix("shown 280,10,20,20") })
        #expect(change.lines.contains { $0.contains("appeared") })
    }

    @Test func aClearContainerHidesItsSubtree() {
        let views = tree()
        views.pane.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        views.pane.alphaValue = 0
        let held = WindowViewGeometry(root: views.root)
        views.pane.alphaValue = 1 // a held region fading in: the pane and its subview show
        #expect(WindowViewGeometry(root: views.root).changes(since: held).total == 2)
    }
}

/// ``WindowFrameBrightness``'s 16x16 grid: a flat picture is one value, and a half-white one is white on one half.
@Suite struct WindowFrameBrightnessGridTests {
    private func image(_ fill: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        fill(context)
        return context.makeImage()
    }

    @Test func aFlatPictureIsOneValueAndHalfWhiteIsHalf() throws {
        let black = try #require(image { $0.setFillColor(CGColor(gray: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) })
        let cells = WindowFrameBrightness.cells(of: black)
        #expect(cells.count == 512)
        #expect(cells == String(repeating: "00", count: 256))
        let half = try #require(image {
            $0.setFillColor(CGColor(gray: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            $0.setFillColor(CGColor(gray: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        })
        let values = stride(from: 0, to: 512, by: 2).map { Int(WindowFrameBrightness.cells(of: half).dropFirst($0).prefix(2), radix: 16) ?? -1 }
        #expect(values.filter { $0 > 240 }.count == 128)
        #expect(values.filter { $0 < 15 }.count == 128)
    }

    @Test func onlyAGridRecorderKeepsCells() throws {
        let black = try #require(image { $0.setFillColor(CGColor(gray: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) })
        let plain = WindowFrameBrightness()
        plain.measure(black)
        #expect(plain.series.cells.isEmpty && plain.series.means.count == 1)
        let grid = WindowFrameBrightness(grid: true)
        grid.measure(black)
        #expect(grid.series.cells.count == 1)
    }
}
#endif
