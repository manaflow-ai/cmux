import Foundation

/// A globally stable notification identity composed from its Mac and Mac-local id.
public struct MobileNotificationFeedItemID: Hashable, Comparable, Sendable {
    /// The stable device identifier of the Mac that emitted the notification.
    public let macDeviceID: String
    /// The notification identifier within that Mac.
    public let notificationID: String

    /// Creates a composite feed identity.
    /// - Parameters:
    ///   - macDeviceID: The stable device identifier of the owning Mac.
    ///   - notificationID: The notification identifier within that Mac.
    public init(macDeviceID: String, notificationID: String) {
        self.macDeviceID = macDeviceID
        self.notificationID = notificationID
    }

    /// Orders identities deterministically by Mac id and then notification id.
    public static func < (lhs: MobileNotificationFeedItemID, rhs: MobileNotificationFeedItemID) -> Bool {
        if lhs.macDeviceID != rhs.macDeviceID {
            return lhs.macDeviceID < rhs.macDeviceID
        }
        return lhs.notificationID < rhs.notificationID
    }
}
