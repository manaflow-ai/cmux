import CoreGraphics
import Darwin

/// What a capture of the app's windows floating above one window takes, read from AppKit on the
/// main actor (``NSWindow/floatingWindowsCapturePlan()``) so the window server calls (its window
/// list and the composite) run on any thread.
nonisolated struct FloatingWindowsCapturePlan: Sendable, Hashable {
    /// The window the floating windows sit above.
    let window: Int
    /// This process: only its windows are painted.
    let pid: pid_t
    /// The window's frame in global display coordinates, the crop of the image.
    let region: CGRect
    /// The window's level.
    let layer: Int
    /// Its visible child windows, which a snapshot composites already.
    let skipping: Set<Int>
    /// Each window of the app's other ordinary window trees to that tree's level.
    let ordinary: [Int: Int]
}
