public import Foundation

/// Clears already-delivered local notifications by identifier.
///
/// A seam over `UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:)`
/// so ``MobileShellComposite`` can react to a Mac-side `notification.dismissed`
/// event without hardcoding the `UNUserNotificationCenter.current()` singleton.
/// The production conformance is ``SystemDeliveredNotificationClearer``; tests
/// inject a fake to assert which ids were cleared.
///
/// The identifiers are the delivered remote notifications' `request.identifier`,
/// which (because the Mac stamps each push with `apns-collapse-id = notificationId`)
/// equal the stable Mac-side notification ids carried in the dismiss event.
public protocol DeliveredNotificationClearing: Sendable {
    /// Remove the delivered notifications with the given identifiers, if present.
    /// - Parameter ids: The delivered-notification identifiers to clear.
    func removeDelivered(ids: [String])
}
