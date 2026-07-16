import CmuxMobileRPC
import Foundation

/// One capability-checked Mac client eligible for notification-feed RPCs.
struct NotificationFeedClientTarget {
    let macDeviceID: String
    let displayName: String
    let client: MobileCoreRPCClient
}
