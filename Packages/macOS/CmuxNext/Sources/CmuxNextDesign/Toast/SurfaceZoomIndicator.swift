public import AppKit

/// A short, quiet readout for the focused surface's current display level.
public struct SurfaceZoomIndicator {
    public init() {}

    /// Shows `percent` as a one-second toast in `window` (it keeps its exact time: it echoes a live change).
    @discardableResult
    @MainActor
    public static func show(percent: Int, in window: NSWindow?) -> CmuxToastHandle? {
        guard let window else { return nil }
        return CmuxToastCenter.shared.show(
            CmuxToast(id: "surface-zoom", message: "\(percent)%", duration: .seconds(1), keepsDuration: true), in: window)
    }
}
