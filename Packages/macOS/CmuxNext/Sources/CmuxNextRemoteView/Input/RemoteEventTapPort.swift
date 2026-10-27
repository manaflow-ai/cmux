import CoreGraphics

/// One installed keyboard event tap as `RemoteSystemShortcutTap` drives it:
/// `QuartzEventTapPort` in the app, a fake in tests (no Accessibility needed).
@MainActor
protocol RemoteEventTapPort: AnyObject {
    /// Turns the tap on again after macOS disabled it.
    func enable()
    /// Disables the tap, takes it off the run loop and invalidates it: its
    /// callback never runs after this returns.
    func invalidate()
}

/// Makes a tap port for the events in `mask`, calling `callback` with
/// `refcon` (a `CallbackToken`'s context); nil when macOS refuses it (no Accessibility).
typealias RemoteEventTapPortFactory = @MainActor (
    _ mask: CGEventMask, _ callback: CGEventTapCallBack, _ refcon: UnsafeMutableRawPointer?
) -> (any RemoteEventTapPort)?

/// A session event tap on the main run loop, enabled from creation.
@MainActor
final class QuartzEventTapPort: RemoteEventTapPort {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    init?(mask: CGEventMask, callback: CGEventTapCallBack, refcon: UnsafeMutableRawPointer?) {
        // SAFETY: `refcon` is a token the callback reads back, never a pointer anything
        // dereferences; Quartz only hands it back.
        guard let port = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: refcon
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func enable() {
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func invalidate() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
