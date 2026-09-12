import AppKit
import Combine
import CmuxTerminal
import ObjectiveC

private var renderHealthOverlayKey: UInt8 = 0
private var renderHealthCancellableKey: UInt8 = 0

extension GhosttySurfaceScrollView {
    var renderHealthOverlayView: TerminalRenderHealthOverlayView? {
        get { objc_getAssociatedObject(self, &renderHealthOverlayKey) as? TerminalRenderHealthOverlayView }
        set { objc_setAssociatedObject(self, &renderHealthOverlayKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var renderHealthCancellable: AnyCancellable? {
        get { objc_getAssociatedObject(self, &renderHealthCancellableKey) as? AnyCancellable }
        set { objc_setAssociatedObject(self, &renderHealthCancellableKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func bindRenderHealth(to terminalSurface: TerminalSurface) {
        renderHealthCancellable?.cancel()
        renderHealthCancellable = terminalSurface.$renderHealth.sink { [weak self] health in
            self?.synchronizeRenderHealthOverlay(health)
        }
        synchronizeRenderHealthOverlay(terminalSurface.renderHealth)
    }

    private func synchronizeRenderHealthOverlay(_ health: TerminalSurfaceRenderHealth) {
        guard health == .notRendering || health == .shellExited else {
            renderHealthOverlayView?.isHidden = true
            return
        }

        let overlay: TerminalRenderHealthOverlayView
        if let existing = renderHealthOverlayView {
            overlay = existing
        } else {
            overlay = TerminalRenderHealthOverlayView(frame: bounds)
            renderHealthOverlayView = overlay
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.frame = bounds
        overlay.apply(health)
    }
}
