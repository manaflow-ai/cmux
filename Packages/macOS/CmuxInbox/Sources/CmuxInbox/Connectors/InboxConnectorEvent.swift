import Foundation

/// Event emitted by a connector into the integration hub.
public enum InboxConnectorEvent: Sendable, Equatable {
    /// Account status changed.
    case account(InboxAccount)
    /// Thread changed.
    case thread(InboxThread)
    /// New or updated item.
    case item(InboxItem)
}
