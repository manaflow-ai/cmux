import AppKit
@testable import CmuxNextLayout
import Testing

/// Crash D (#24998, fuzz seed 21 on macOS 26.6.2, ⌥⌘= `canvasZoomIn`): the canvas camera sets a bounds
/// size other than the frame size, AppKit reports that as a backing change inside `setBoundsSize`, and
/// `ScreenContentView` reconciled for every backing change; reconcile sets the camera's bounds again, so
/// the main thread recursed until the stack overflowed. A screen lays out again only for a real backing
/// scale change, and never from inside its own camera change.
@MainActor @Suite(.serialized)
struct ScreenBackingChangeTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A two-pane screen in a layer-backed window, reconciled once.
    final class Screen {
        let panes = Panes()
        let context: LayoutViewContext
        let view: ScreenContentView
        let window: NSWindow
        static let tree = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

        init() {
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.tree))],
                                    activeScreenID: "s", focusedPane: "p1")
            context = LayoutViewContext(model: model, provider: panes)
            context.livePanes = Set(Self.tree.panes)
            view = ScreenContentView(screenID: "s", layout: .splits(Self.tree), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.reconcile(animated: false)
        }

        /// The screen as a canvas of its two panes, shown through `camera`.
        func showCanvas(_ camera: CanvasCamera) {
            let canvas = CanvasScreen(frames: ["p1": CGRect(x: 0, y: 0, width: 584, height: 800),
                                               "p2": CGRect(x: 600, y: 0, width: 584, height: 800)], camera: camera)
            view.update(layout: .splits(Self.tree), canvas: canvas, animated: false)
        }
    }

    @Test func aBackingChangeAtTheSameScaleDoesNotLayOutAgain() {
        let screen = Screen()
        defer { screen.window.close() }
        let before = screen.view.reconcilePasses
        screen.view.viewDidChangeBackingProperties()
        #expect(screen.view.reconcilePasses == before, "a backing callback with the scale unchanged reconciled")
    }

    @Test func aCanvasZoomSetsItsBoundsWithoutReenteringReconcile() {
        let screen = Screen()
        defer { screen.window.close() }
        let center = CGPoint(x: 600, y: 400)
        screen.showCanvas(CanvasCamera(center: center))
        let before = screen.view.reconcilePasses
        // Zoom In: the bounds become smaller than the frame (AppKit's backing callback comes inside it).
        screen.showCanvas(CanvasCamera(center: center).zoomed(by: CanvasCamera.zoomStep))
        #expect(screen.view.reconcilePasses == before + 1, "one zoom ran \(screen.view.reconcilePasses - before) reconcile passes")
        #expect(abs(screen.view.bounds.width - 1200 / CanvasCamera.zoomStep) < 1, "the camera did not set the bounds: \(screen.view.bounds)")
        #expect(!screen.view.isApplyingCamera)
    }
}
