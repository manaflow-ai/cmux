public import Foundation

/// One normalized external event for a batched inbox push.
public struct InboxPushRecord: Sendable {
    /// Account status record for the pushed event.
    public let account: InboxAccount
    /// Thread the pushed item belongs to.
    public let thread: InboxThread
    /// The pushed item.
    public let item: InboxItem

    /// Creates a push record.
    /// - Parameters:
    ///   - account: Account status record for the pushed event.
    ///   - thread: Thread the pushed item belongs to.
    ///   - item: The pushed item.
    public init(account: InboxAccount, thread: InboxThread, item: InboxItem) {
        self.account = account
        self.thread = thread
        self.item = item
    }
}
