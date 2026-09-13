import AppKit
import CmuxTerminal
import ObjectiveC

private var renderHealthControllerKey: UInt8 = 0

extension GhosttySurfaceScrollView {
    private var renderHealthController: TerminalRenderHealthOverlayController {
        if let existing = objc_getAssociatedObject(self, &renderHealthControllerKey) as? TerminalRenderHealthOverlayController {
            return existing
        }
        let controller = TerminalRenderHealthOverlayController()
        objc_setAssociatedObject(self, &renderHealthControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    func attachRenderHealthOverlay(to surface: TerminalSurface) {
        renderHealthController.attach(host: self, surface: surface)
    }

    func updateRenderHealthOverlayFrame(_ frame: NSRect) {
        renderHealthController.updateFrame(frame)
    }
}
