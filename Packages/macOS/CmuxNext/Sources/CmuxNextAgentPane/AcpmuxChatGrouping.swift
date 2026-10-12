import Foundation

/// The grouping choices shown by the Chats sidebar.
public nonisolated enum AcpmuxChatGrouping: String, CaseIterable, Hashable, Sendable {
    case harness
    case folder
    case account
}
