import AppKit
import CmuxNextDesign

/// A short, quiet readout for the focused surface's current display level.
enum SurfaceZoomIndicator {
    @discardableResult
    @MainActor
    static func show(percent: Int, in window: NSWindow?) -> CmuxToastHandle? {
        guard let window else { return nil }
        return CmuxToastCenter.shared.show(
            CmuxToast(id: "surface-zoom", message: "\(percent)%", duration: .seconds(1)), in: window)
    }
}
