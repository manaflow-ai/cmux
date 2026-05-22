import AppKit

@MainActor
private enum CrApplicationSendEventState {
    static var isHandlingSendEvent = false
}

extension NSApplication {
    /// Chromium's macOS event bridge sends these selectors to `NSApp`
    /// directly. Keep them on `NSApplication` itself so CEF still works
    /// when SwiftUI creates the shared app before `NSPrincipalClass` takes
    /// effect and the runtime object is a plain `NSApplication`.
    @objc dynamic var isHandlingSendEvent: Bool {
        get { CrApplicationSendEventState.isHandlingSendEvent }
        set { CrApplicationSendEventState.isHandlingSendEvent = newValue }
    }

    @objc dynamic func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        isHandlingSendEvent = handlingSendEvent
    }
}

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
    override func sendEvent(_ event: NSEvent) {
        let was = isHandlingSendEvent
        isHandlingSendEvent = true
        super.sendEvent(event)
        isHandlingSendEvent = was
    }
}
