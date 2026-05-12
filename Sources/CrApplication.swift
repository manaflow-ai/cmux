import AppKit

/// `NSApplication` subclass that satisfies Chromium's `CrAppProtocol`.
///
/// CEF Chrome runtime expects `NSApplication.shared` to respond to
/// `isHandlingSendEvent` / `setHandlingSendEvent:`. Without this, CEF
/// asserts and aborts the process during the first event dispatch.
///
/// Activated via `NSPrincipalClass = CrApplication` in `Resources/Info.plist`.
/// Behaviour for non-CEF code paths is unchanged: a regular `NSApplication`
/// with no extra observable state.
@objc(CrApplication)
final class CrApplication: NSApplication {
    private var handlingSendEventStorage = false

    @objc var isHandlingSendEvent: Bool {
        get { handlingSendEventStorage }
        set { handlingSendEventStorage = newValue }
    }

    @objc func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        handlingSendEventStorage = handlingSendEvent
    }

    override func sendEvent(_ event: NSEvent) {
        let was = handlingSendEventStorage
        handlingSendEventStorage = true
        super.sendEvent(event)
        handlingSendEventStorage = was
    }
}
