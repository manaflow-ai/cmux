public import CoreGraphics

/// What a window server capture of a window takes, read from AppKit on the main actor
/// (``NSWindow/compositedCapturePlan(adding:includeChild:)``) so the capture itself
/// (``NSWindow/capture(_:)``) runs on any thread.
public nonisolated struct WindowCapturePlan: Sendable, Hashable {
    /// The window numbers: one window, or the window and the child windows composited with it.
    public var numbers: [Int]
    /// The window's frame in global display coordinates for a composite; nil for one window.
    public var frame: CGRect?

    public init(numbers: [Int], frame: CGRect?) {
        self.numbers = numbers
        self.frame = frame
    }
}
