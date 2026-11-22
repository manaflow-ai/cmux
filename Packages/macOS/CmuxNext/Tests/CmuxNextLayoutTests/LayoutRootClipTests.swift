import AppKit
import Testing
@testable import CmuxNextLayout

/// A strip column that scrolls past the layout's leading edge is cut at that
/// edge: nothing of it draws over the window sidebar beside the layout, on
/// screen (the layer mask) and in AppKit's own rendering (`cacheDisplay`, the
/// path of `debug.window_snapshot`). Guard for preflight nxdog71-v2, whose
/// in-process snapshot showed web page content of the scrolled-out column
/// under the sidebar while the screen showed it cut (a capture artifact of
/// web content, not a layout overlap).
@MainActor
struct LayoutRootClipTests {
    private let screen = LayoutScreen(id: "s", name: "", layout: .columns([
        LayoutColumn(id: "c1", width: 0.8, root: .leaf("a")),
        LayoutColumn(id: "c2", width: 0.8, root: .leaf("b")),
    ]))
    static let sidebarWidth: CGFloat = 200

    @Test func aColumnScrolledPastTheLeadingEdgeNeverDrawsOverTheSidebar() async throws {
        let model = LayoutModel(screens: [screen], activeScreenID: "s", focusedPane: "a")
        let provider = SolidPaneProvider()
        let window = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 400))
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.frame = CGRect(x: Self.sidebarWidth, y: 0, width: 900, height: 400)
        window.addSubview(root)
        root.layoutSubtreeIfNeeded()

        // Focus the second column: the strip scrolls the first one partly out
        // past the leading edge (the sidebar side), as Show Memory does.
        model.focus("b")
        await waitUntil { (root.frame(of: "a")?.minX ?? 0) < -50 && (root.frame(of: "a")?.maxX ?? 0) > 50 }
        let frame = try #require(root.frame(of: "a"))
        #expect(frame.minX < 0 && frame.maxX > 0, "the first column must be partly scrolled out (\(frame))")

        let rep = try #require(window.bitmapImageRepForCachingDisplay(in: window.bounds))
        window.cacheDisplay(in: window.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / window.bounds.width
        func isColumn(atX x: CGFloat) -> Bool {
            guard let color = rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
            // sRGB red reads about 1.00/0.15/0.00 in device RGB.
            return color.alphaComponent > 0.9 && color.redComponent > 0.9 && color.greenComponent < 0.3 && color.blueComponent < 0.1
        }
        // The visible part of the column draws (the probe works) ...
        #expect(isColumn(atX: Self.sidebarWidth + 10))
        // ... and none of it draws in the sidebar.
        for x in stride(from: CGFloat(5), to: Self.sidebarWidth, by: 15) {
            #expect(!isColumn(atX: x), "the scrolled-out column draws over the sidebar at x=\(x)")
        }
        withExtendedLifetime(provider) {}
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        if !condition() { Issue.record("the condition never held", sourceLocation: sourceLocation) }
    }
}

/// A pane that paints itself solid red (drawn, so `cacheDisplay` renders it).
private final class SolidPaneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

private final class SolidPaneProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView {
        pane == "a" ? SolidPaneView() : NSView()
    }
}
