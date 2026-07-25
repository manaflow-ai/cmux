import CmuxMobileRPC
import Foundation

/// One capability-checked Mac client eligible for notification-feed RPCs.
struct NotificationFeedClientTarget {
    let macDeviceID: String
    /// The pairing's app-instance tag, or `nil` for a legacy untagged pairing.
    let instanceTag: String?
    let displayName: String
    let client: MobileCoreRPCClient
}
