import AppKit

/// Borderless screensaver window for Sleepy Mode. Any key or click wakes it
/// (it is deliberately not a lock); the controller wires `onExit` to deactivate.
final class SleepyOverlayWindow: NSWindow {
    /// Invoked on any key/click to dismiss the screensaver.
    var onExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onExit?() }
    override func rightMouseDown(with event: NSEvent) { onExit?() }
}
