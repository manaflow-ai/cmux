public import AppKit
import os
import ServiceManagement

/// `app.backgroundReady`'s login item (After Quit and at Login): the app itself (`SMAppService.mainApp`),
/// registered while the library says so (``BackgroundReadyRules/registersLoginItem(_:)``), and how a launch
/// tells it was opened as one.
@MainActor
public struct BackgroundReadyLoginItem {
    public init() {}
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.background-ready")

    /// Registers or unregisters the app as a login item; one already in that state is left alone.
    static func apply(registers: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        guard registers != registered else { return }
        do {
            if registers { try service.register() } else { try service.unregister() }
            logger.notice("login item \(registers ? "registered" : "unregistered", privacy: .public)")
        } catch {
            logger.error("login item \(registers ? "register" : "unregister", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The launch's open-application Apple event says the system opened cmux as a login item.
    public static func launchedAsLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
