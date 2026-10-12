import AppKit
import CmuxNextBridge
import CmuxNextLayout
import CmuxNextTabs

/// Drag a pane by its tab bar onto another pane to swap them (cx-8bv1j, iTerm's pane drag). The
/// press starts on empty strip space that does not move the window (the top row's does); tabs,
/// chips and + keep their own presses. The pane under the pointer is outlined, and the drop swaps.
@MainActor
final class PaneSwapDrag: NSObject, NSGestureRecognizerDelegate {
    private weak var strip: TabStripView?
    private let pane: LayoutPaneID
    private let layout: () -> LayoutRootView?
    private let swap: (LayoutPaneID, LayoutPaneID) -> Void

    init(strip: TabStripView, pane: LayoutPaneID, layout: @escaping () -> LayoutRootView?,
         swap: @escaping (LayoutPaneID, LayoutPaneID) -> Void) {
        self.strip = strip
        self.pane = pane
        self.layout = layout
        self.swap = swap
        super.init()
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        recognizer.delegate = self
        strip.addGestureRecognizer(recognizer)
    }

    /// A pane's drag: a drop sends `swap-pane` to its daemon.
    convenience init(pane: PaneController) {
        self.init(strip: pane.view.stripView, pane: pane.layoutPaneID, layout: { [weak pane] in pane?.workspace?.layoutView },
                  swap: { [weak pane] from, to in
                      guard let pane, let content = pane.workspace, let from = content.handles.panes[from],
                            let to = content.handles.panes[to] else { return }
                      pane.daemon.send("swap-pane") { try await $0.swapPane(from, with: .pane(to)) }
                  })
    }

    func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool {
        guard let strip else { return false }
        let point = recognizer.location(in: nil)
        return strip.titlebarHit(at: strip.convert(point, from: nil)) == .empty && strip.titlebarPress(atWindowPoint: point) == .staysPut
    }

    @objc private func pan(_ recognizer: NSPanGestureRecognizer) {
        guard let layout = layout() else { return }
        let target = other(at: recognizer.location(in: layout), in: layout)
        switch recognizer.state {
        case .began, .changed:
            if let target, let frame = layout.frame(of: target), let window = layout.window {
                layout.showTabDragOutline(screenRect: window.convertToScreen(layout.convert(frame, to: nil)))
            } else {
                layout.hideTabDragHighlight()
            }
        case .ended:
            layout.cancelTabDrag()
            if let target { swap(pane, target) }
        default:
            layout.cancelTabDrag()
        }
    }

    /// The pane under `point` (layout coordinates) when it is not this one.
    private func other(at point: CGPoint, in layout: LayoutRootView) -> LayoutPaneID? {
        layout.navigationFrames.keys.first { $0 != pane && layout.frame(of: $0)?.contains(point) == true }
    }
}
