import Foundation

/// Immutable source-chip snapshot for Inbox UI rows and tests.
public struct InboxSourceChipSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// Source represented by the chip.
    public let source: InboxSource?
    /// Display label.
    public let label: String
    /// SF Symbol name for the source.
    public let symbolName: String
    /// Unread badge count.
    public let unreadCount: Int
    /// Whether the chip is selected.
    public let isSelected: Bool
    /// Most severe account status for the source.
    public let status: InboxAccountStatus?

    /// Stable identity.
    public var id: String { source?.rawValue ?? "all" }

    /// Creates a source chip snapshot.
    public init(
        source: InboxSource?,
        label: String,
        symbolName: String,
        unreadCount: Int,
        isSelected: Bool,
        status: InboxAccountStatus? = nil
    ) {
        self.source = source
        self.label = label
        self.symbolName = symbolName
        self.unreadCount = unreadCount
        self.isSelected = isSelected
        self.status = status
    }
}
