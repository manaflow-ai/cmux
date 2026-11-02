import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Every frame of a layout motion puts each pane and divider on the device-pixel grid of the window
/// (RESIZE VIDEOS, Lawrence 2026-11-02: "resizing columns is still not animating pixel perfect").
/// The pane springs were rounded to the grid, but the camera offsets (the strip scroll, a row
/// column's scroll, a scroll area's) and a screen's slide were added after that rounding, and they
/// are spring values too: every pane edge then sat a fraction of a device pixel off the grid for the
/// whole motion, so Core Animation resampled the terminal and page contents (soft text, a seam that
/// flickers between one and two pixels). Frames step at a fixed 120 Hz dt; every check is in window
/// coordinates, where the display's pixels are.
@MainActor
@Suite(.closesItsWindows)
struct PresentedPixelGridTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120

    final class Strip {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(screens: [LayoutScreen], focused: PaneID) {
            model = LayoutModel(screens: screens, activeScreenID: screens.first?.id, focusedPane: focused)
            model.rowsEnabledOverride = true
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
        }

        convenience init(_ layout: ScreenLayout, focused: PaneID) {
            self.init(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], focused: focused)
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
        var scale: CGFloat { window.backingScaleFactor }

        @discardableResult
        func step() -> Bool { root.advanceFrame(PresentedPixelGridTests.dt) }

        func settle() { for _ in 0..<600 where step() {} }

        /// The edges of every shown pane host and divider of every shown screen, in window points, that
        /// are not on a device pixel (more than a thousandth of a pixel off).
        func offGrid() -> [String] {
            var off: [String] = []
            func check(_ name: String, _ view: NSView) {
                let rect = view.convert(view.bounds, to: nil)
                for (edge, value) in [("minX", rect.minX), ("maxX", rect.maxX), ("minY", rect.minY), ("maxY", rect.maxY)] {
                    let pixels = value * scale
                    if abs(pixels - pixels.rounded()) > 0.001 { off.append("\(name).\(edge)=\(value)") }
                }
            }
            for (id, screen) in root.screenViews where !screen.isHidden {
                for (pane, host) in root.context.hosts where host.superview === screen && !host.isHidden {
                    check("\(id)/\(pane.rawValue)", host)
                }
                for (kind, view) in screen.dividerViews where !view.isHidden {
                    check("\(id)/\(kind)", view)
                }
            }
            return off
        }

        /// Steps until the layout rests and returns each frame's off-grid edges (frame number first).
        func stepRecordingOffGrid() -> [(frame: Int, edges: [String])] {
            var found: [(Int, [String])] = []
            let first = offGrid()
            if !first.isEmpty { found.append((0, first)) }
            for frame in 1...600 {
                let moving = step()
                let off = offGrid()
                if !off.isEmpty { found.append((frame, off)) }
                if !moving { break }
            }
            return found
        }
    }

    static func columns(_ count: Int, width: Double = 0.5, prefix: String = "") -> ScreenLayout {
        .columns((1...count).map {
            LayoutColumn(id: ColumnID("\(prefix)c\($0)"), width: width, root: .leaf(PaneID("\(prefix)p\($0)")))
        })
    }

    /// The strip camera moving on its scroll spring (a focus move to a column off screen) carries every
    /// strip pane and column edge; each one stays on the device-pixel grid in every frame.
    @Test func aStripCameraMoveKeepsEveryPaneOnThePixelGrid() {
        let strip = Strip(Self.columns(4, width: 0.45), focused: "p4")
        defer { strip.window.closeAfterTest() }
        #expect(strip.offGrid().isEmpty, "at rest everything is on the grid: \(strip.offGrid())")
        let before = strip.screen.scroll.value
        strip.model.focus("p1", notify: false)
        strip.root.syncWithModel()
        #expect(abs(strip.screen.scroll.target - before) > 50, "focusing p1 moves the camera (\(before) -> \(strip.screen.scroll.target))")
        let off = strip.stepRecordingOffGrid()
        #expect(off.isEmpty, "frames with an edge off the device grid (scale \(strip.scale)): \(off.prefix(4))")
    }

    /// Closing the focused last column of a scrolled strip: the camera rides the close spring while the
    /// panes move (`scrollRidesFrames`); every pane and divider stays on the grid.
    @Test func aCloseWithACameraShiftKeepsEveryPaneOnThePixelGrid() {
        let strip = Strip(Self.columns(3), focused: "p3")
        defer { strip.window.closeAfterTest() }
        #expect(strip.screen.scroll.value > 100, "three half-width columns scroll to the end for p3")
        strip.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: Self.columns(2))])
        strip.root.syncWithModel()
        strip.model.focus("p2", notify: false)
        strip.root.syncWithModel()
        let off = strip.stepRecordingOffGrid()
        #expect(off.isEmpty, "frames with an edge off the device grid (scale \(strip.scale)): \(off.prefix(4))")
    }

    /// A screen switch slides the incoming screen in from the side: its panes stay on the grid while it slides.
    @Test func aScreenSwitchKeepsEveryPaneOnThePixelGrid() {
        let strip = Strip(screens: [LayoutScreen(id: "s", name: "s", layout: Self.columns(2)),
                                    LayoutScreen(id: "t", name: "t", layout: Self.columns(2, prefix: "t"))],
                          focused: "p1")
        defer { strip.window.closeAfterTest() }
        strip.model.selectScreen("t")
        strip.root.syncWithModel()
        #expect(strip.root.screenViews["t"]?.isHidden == false, "the second screen shows")
        let off = strip.stepRecordingOffGrid()
        #expect(off.isEmpty, "frames with an edge off the device grid (scale \(strip.scale)): \(off.prefix(4))")
    }
}
