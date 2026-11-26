#if DEBUG
import AppKit

/// One image composited over AppKit's permission-free window snapshot.
struct WindowScreenshotOverlay {
    let image: CGImage
    let rect: NSRect
    let clipRect: NSRect
    let alpha: CGFloat
    let zOrder: [Int]
}
#endif
