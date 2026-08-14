import Foundation

/// Identifies the coordinator preference that was current when work was made.
///
/// The value is mirrored through the shared defaults suite before asynchronous
/// work is created. Direct service mutations replace it, so a coordinator task
/// that starts late cannot reverse a newer direct preference.
public struct PushRegistrationIntentEpoch: Sendable, Equatable {
    /// The shared-defaults key containing the currently authoritative epoch.
    public static let defaultsKey = "cmux.notifications.pushIntentEpoch"

    /// The stable value persisted and carried by asynchronous coordinator work.
    public let storageValue: String

    /// Creates a fresh preference epoch.
    public init() {
        self.storageValue = UUID().uuidString
    }

    /// Restores an epoch from its persisted representation.
    public init(storageValue: String) {
        self.storageValue = storageValue
    }
}
