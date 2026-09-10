import CoreGraphics

/// Identity and AppKit geometry of one external application window.
struct ExternalApplicationWindowSnapshot: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerProcessIdentifier: pid_t
    let frame: CGRect
}
