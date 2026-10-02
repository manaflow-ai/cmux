import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// The focus ring follows every resize in the same layout pass that places
/// the panes: after the pass that moves the panes (a window resize, the
/// sidebar resizing the layout root, a niri column scroll), the ring's
/// stroke rect equals the focused pane's rounded content rect, with the
/// overlay plane in the root and with the plane adopted by a window overlay
/// above Chromium pages (a second window whose layout pass is not this one).
@MainActor
struct FocusRingResizeTests {
    /// A window that lifts the plane into a second window, as
    /// `WindowOverlayLayer` does while a Chromium page shows.
    private final class OverlayHostWindow: NSWindow, OverlayPlaneHosting {
        let overlay: NSWindow
        init(frame: CGRect) {
            overlay = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            overlay.isReleasedWhenClosed = false
            let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            overlay.contentView = container
            super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
        }
        func adoptPlane(_ plane: OverlayPlane) {
            overlay.contentView?.addSubview(plane)
            plane.syncFrame()
        }
        func releasePlane(_ plane: OverlayPlane) {}
        func interactiveOverlayRectsDidChange(_ plane: OverlayPlane) {}
        func planeDidLayout(_ plane: OverlayPlane) {}
        func paneShapesDidChange(_ plane: OverlayPlane) {}
    }

    private func makeRoot(_ layout: ScreenLayout, focused: PaneID, adopted: Bool) -> (LayoutRootView, NSWindow, Provider) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: layout)], activeScreenID: "s", focusedPane: focused)
        model.followsDesignMetrics = false
        var style = LayoutStyle()
        style.panePadding = 4
        style.paneCornerRadius = 8
        style.focusRing.width = 2
        model.baseStyle = style
        let provider = Provider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let window: NSWindow = adopted
            ? OverlayHostWindow(frame: frame)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: frame)
        window.contentView = container
        container.addSubview(view)
        view.frame = container.bounds
        container.layoutSubtreeIfNeeded()
        return (view, window, provider)
    }

    /// The ring's stroke rect and the focused pane's rounded content rect,
    /// both in the root's (= the plane's) coordinates.
    private func rects(_ view: LayoutRootView, _ pane: PaneID) -> (ring: CGRect, pane: CGRect)? {
        guard let host = view.context.hosts[pane], host.chrome.showsRing else { return nil }
        let chrome = host.chrome
        let ring = chrome.ringFrame.offsetBy(dx: chrome.frame.minX, dy: chrome.frame.minY)
        return (ring, view.convert(host.roundedRect, from: host))
    }

    /// The layout pass that places the panes for a new root size: the
    /// parent sets the root's frame, then the root lays out. Nothing else
    /// runs (no pass of the window that hosts the plane).
    private func resizeRoot(_ view: LayoutRootView, to size: CGSize) {
        view.frame = CGRect(origin: view.frame.origin, size: size)
        view.layout()
    }

    private static let sizes: [CGSize] = [
        CGSize(width: 900, height: 600), CGSize(width: 1400, height: 820), CGSize(width: 640, height: 420),
        CGSize(width: 1201, height: 699), CGSize(width: 1000.5, height: 650.5), CGSize(width: 1200, height: 700),
    ]

    private func checkSplits(adopted: Bool) {
        let tree: SplitNode = .split("s1", axis: .horizontal, ratio: 0.5,
                                     a: .leaf("a"), b: .split("s2", axis: .vertical, ratio: 0.4, a: .leaf("b"), b: .leaf("c")))
        let (view, window, provider) = makeRoot(.splits(tree), focused: "c", adopted: adopted)
        defer { window.close(); (window as? OverlayHostWindow)?.overlay.close() }
        #expect(view.overlayPlane.isHome == !adopted)
        for size in Self.sizes {
            resizeRoot(view, to: size)
            let got = rects(view, "c")
            #expect(got != nil, "ring shows at \(size)")
            if let got { #expect(got.ring == got.pane, "size \(size) adopted \(adopted)") }
        }
        // The layout root moves inside its window (sidebar shown or hidden).
        for x in [CGFloat(208), 0, 150] {
            view.frame = CGRect(x: x, y: 0, width: 1200 - x, height: 700)
            view.layout()
            if let got = rects(view, "c") { #expect(got.ring == got.pane, "origin \(x) adopted \(adopted)") }
            if adopted { #expect(view.overlayPlane.isInSync, "plane follows the root at origin \(x)") }
        }
        withExtendedLifetime(provider) {}
    }

    @Test func ringFollowsEveryResizeWithThePlaneInTheRoot() {
        checkSplits(adopted: false)
    }

    @Test func ringFollowsEveryResizeWithThePlaneAboveChromiumPages() {
        checkSplits(adopted: true)
    }

    @Test func ringFollowsAWindowResizeOfAColumnsScreen() {
        let columns: ScreenLayout = .columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 0.5, root: .split("s", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))),
            LayoutColumn(id: "c3", width: 0.5, root: .leaf("d")),
        ])
        for adopted in [false, true] {
            let (view, window, provider) = makeRoot(columns, focused: "b", adopted: adopted)
            defer { window.close(); (window as? OverlayHostWindow)?.overlay.close() }
            for size in Self.sizes {
                resizeRoot(view, to: size)
                let got = rects(view, "b")
                #expect(got != nil, "ring shows at \(size)")
                if let got { #expect(got.ring == got.pane, "size \(size) adopted \(adopted)") }
            }
            withExtendedLifetime(provider) {}
        }
    }

    private final class Provider: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }
}
