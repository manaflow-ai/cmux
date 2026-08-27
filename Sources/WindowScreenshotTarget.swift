#if DEBUG
import CoreGraphics

/// Holds a window identifier only when AppKit's signed number fits Core Graphics.
struct WindowScreenshotTarget: Sendable, Equatable {
    let windowID: CGWindowID

    init?(windowNumber: Int) {
        guard let windowID = CGWindowID(exactly: windowNumber) else { return nil }
        self.windowID = windowID
    }
}
#endif
