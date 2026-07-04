import CoreGraphics

/// Frontmost window metadata captured from `CGWindowList`.
struct AppshotFrontmostWindow: Sendable {
    let windowID: CGWindowID
    let title: String
    /// Window frame in top-left-origin global screen coordinates (the same
    /// space AX `kAXPosition`/`kAXSize` report), used to bind the AX read to
    /// the exact window the screenshot captured. `nil` when CGWindowList did
    /// not report bounds.
    let bounds: CGRect?
}
