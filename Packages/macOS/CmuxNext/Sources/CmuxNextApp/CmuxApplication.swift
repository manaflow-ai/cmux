import AppKit

/// The app's NSApplication. Implements CEF's `CefAppProtocol` informal
/// methods so Chromium can tell when an event is being dispatched through
/// `sendEvent:` (nested run loops, menu tracking). With this class in place
/// the CEF shim no longer needs to inject these methods at runtime.
final class CmuxApplication: NSApplication {
    private var handlingSendEvent = false

    @objc(isHandlingSendEvent)
    func isHandlingSendEvent() -> Bool { handlingSendEvent }

    @objc(setHandlingSendEvent:)
    func setHandlingSendEvent(_ value: Bool) { handlingSendEvent = value }

    override func sendEvent(_ event: NSEvent) {
        let previous = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = previous }
        super.sendEvent(event)
    }
}
