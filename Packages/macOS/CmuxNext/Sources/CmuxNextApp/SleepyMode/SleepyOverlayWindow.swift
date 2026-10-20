import AppKit

/// One screen's borderless Sleepy Mode window, above everything at screensaver
/// level. Any key or click wakes (it is deliberately not a lock).
final class SleepyOverlayWindow: NSWindow {
    static let identifierValue = NSUserInterfaceItemIdentifier("cmux.next.sleepyMode")

    /// Runs on any key or click.
    var onWake: (() -> Void)?

    init(screen: NSScreen?, frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        identifier = Self.identifierValue
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) { onWake?() }
    override func mouseDown(with event: NSEvent) { onWake?() }
    override func rightMouseDown(with event: NSEvent) { onWake?() }

    /// Menu key equivalents (Cmd-Q, Cmd-W) resolve before `keyDown`: here they
    /// wake the scene instead of acting on the windows behind it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onWake?()
        return true
    }
}
