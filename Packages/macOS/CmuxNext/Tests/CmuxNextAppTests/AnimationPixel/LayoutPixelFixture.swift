import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation

/// A real `LayoutRootView` in a real borderless window on a 120 Hz virtual display (1x or 2x,
/// light or dark), with each pane drawn as one opaque color with edge antialiasing on: a pane
/// edge off the device-pixel grid then draws a blended pixel the capture sees. Focus ring, pane
/// dim and headers are off, so every pane is one flat color on the scanline.
///
/// Pins the motion settings the oracle assumes (speed fast, bounce none, pane animations on,
/// Reduce Motion off, the master switch as asked) and puts them back in ``close()``.
@MainActor
final class LayoutPixelFixture {
    /// Pane colors (sRGB), far apart in every channel.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.86, green: 0.20, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.16, green: 0.62, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.36, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.92, green: 0.74, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.22, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.10, green: 0.70, blue: 0.74, alpha: 1),
    ]

    final class SolidPanes: LayoutPaneContentProvider {
        var colors: [PaneID: NSColor] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = (colors[pane] ?? .black).cgColor
            view.layer?.isOpaque = true
            view.layer?.allowsEdgeAntialiasing = true
            view.layer?.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
            return view
        }
    }

    let display: VirtualDisplay120
    let window: NSWindow
    let model: LayoutModel
    let root: LayoutRootView
    let panes = SolidPanes()
    let scale: CGFloat
    private let restore: () -> Void

    init(layout: ScreenLayout, focused: PaneID, scale: Int, dark: Bool, animations: Bool = true,
         size: CGSize = CGSize(width: 1200, height: 700)) async throws {
        let design = DesignSettings.shared
        let saved = (design.animationsEnabled, design.animationSpeed, design.animationBounce, design.paneAnimations, Motion.reduceMotionOverride)
        restore = {
            design.animationsEnabled = saved.0
            design.animationSpeed = saved.1
            design.animationBounce = saved.2
            design.paneAnimations = saved.3
            Motion.reduceMotionOverride = saved.4
        }
        design.animationsEnabled = animations
        design.animationSpeed = .fast
        design.animationBounce = .none
        design.paneAnimations = true
        Motion.reduceMotionOverride = false
        display = try await VirtualDisplay120(points: CGSize(width: 1600, height: 1000), scale: scale)
        self.scale = CGFloat(scale)
        for (index, pane) in layout.panes.enumerated() { panes.colors[pane] = Self.colors[index % Self.colors.count] }
        model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
        model.followsDesignMetrics = false
        model.baseStyle.inactivePaneDimming = 0
        model.baseStyle.unfocusedPaneDim = UnfocusedPaneDim()
        root = LayoutRootView(model: model, contentProvider: panes)
        let visible = display.screen.visibleFrame
        let frame = CGRect(x: (visible.minX + 40).rounded(), y: (visible.minY + 40).rounded(), width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: display.screen)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        guard window.screen == display.screen, window.backingScaleFactor == CGFloat(scale) else {
            throw VirtualDisplay120.Failure(description: "the test window is on \(window.screen?.localizedName ?? "no screen") at "
                + "\(window.backingScaleFactor)x, not on the \(scale)x virtual display")
        }
        root.layoutSubtreeIfNeeded()
    }

    var screen: ScreenContentView? { root.screenViews["s"] }

    /// The views the layer channel samples: every pane host, its content view, and every divider.
    func sampledViews() -> [String: NSView] {
        guard let screen else { return [:] }
        var views: [String: NSView] = [:]
        for subview in screen.subviews {
            if let host = subview as? PaneHostView {
                views["host:\(host.pane.rawValue)"] = host
                views["content:\(host.pane.rawValue)"] = host.content
            } else if let divider = subview as? DividerHandleView {
                views["divider:\(divider.kind.mouseAreaID)"] = divider
            }
        }
        return views
    }

    /// Waits until the screen has no motion, at most `limit`.
    func settle(within limit: Duration = .seconds(3)) async throws {
        let clock = ContinuousClock(), end = clock.now + limit
        while screen?.hasMotion == true, clock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    func close() {
        window.closeAfterTest()
        restore()
    }
}
