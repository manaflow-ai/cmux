import CoreGraphics

/// Identity and AppKit geometry of one external application window.
struct ExternalApplicationWindowSnapshot: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerProcessIdentifier: pid_t
    let frame: CGRect
    let isOnScreen: Bool

    init(windowID: CGWindowID, ownerProcessIdentifier: pid_t, frame: CGRect, isOnScreen: Bool = true) {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}
