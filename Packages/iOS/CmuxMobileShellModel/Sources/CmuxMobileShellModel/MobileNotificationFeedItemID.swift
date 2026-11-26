import CMUXMobileCore
import Foundation

/// A globally stable notification identity composed from its Mac and Mac-local id.
public struct MobileNotificationFeedItemID: Hashable, Comparable, Sendable {
    /// The stable device identifier of the Mac that emitted the notification.
    public let macDeviceID: String
    /// The app-instance tag of the Mac pairing that emitted the notification,
    /// or `nil` for a legacy untagged pairing. Part of the identity so sibling
    /// builds of one Mac never collapse notifications sharing a Mac-local id.
    public let macInstanceTag: String?
    /// The notification identifier within that Mac.
    public let notificationID: String

    /// Creates a composite feed identity.
    /// - Parameters:
    ///   - macDeviceID: The stable device identifier of the owning Mac.
    ///   - macInstanceTag: The owning pairing's app-instance tag, or `nil`.
    ///   - notificationID: The notification identifier within that Mac.
    public init(macDeviceID: String, macInstanceTag: String? = nil, notificationID: String) {
        let identity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: macInstanceTag
        )
        self.macDeviceID = identity.macDeviceID
        self.macInstanceTag = identity.instanceTag
        self.notificationID = notificationID
    }

    /// Orders identities deterministically by Mac id and then notification id.
    public static func < (lhs: MobileNotificationFeedItemID, rhs: MobileNotificationFeedItemID) -> Bool {
        if lhs.macDeviceID != rhs.macDeviceID {
            return lhs.macDeviceID < rhs.macDeviceID
        }
        if lhs.macInstanceTag != rhs.macInstanceTag {
            return (lhs.macInstanceTag ?? "") < (rhs.macInstanceTag ?? "")
        }
        return lhs.notificationID < rhs.notificationID
    }
}
