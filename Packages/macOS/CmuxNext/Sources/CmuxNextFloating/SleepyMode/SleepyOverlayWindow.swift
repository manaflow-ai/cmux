public import AppKit

/// One screen's borderless Sleepy Mode window, above everything at screensaver
/// level. Any key or click wakes (it is deliberately not a lock).
public final class SleepyOverlayWindow: NSWindow {
    public static let identifierValue = NSUserInterfaceItemIdentifier("cmux.next.sleepyMode")

    /// Runs on any key or click.
    public var onWake: (() -> Void)?

    public init(screen: NSScreen?, frame: NSRect) {
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

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    override public func keyDown(with event: NSEvent) { onWake?() }
    override public func mouseDown(with event: NSEvent) { onWake?() }
    override public func rightMouseDown(with event: NSEvent) { onWake?() }

    /// Menu key equivalents (Cmd-Q, Cmd-W) resolve before `keyDown`: here they
    /// wake the scene instead of acting on the windows behind it.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        onWake?()
        return true
    }
}
