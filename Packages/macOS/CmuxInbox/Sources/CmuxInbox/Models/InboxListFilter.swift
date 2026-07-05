import Foundation

/// High-level row filter used by the Inbox UI and socket API.
public enum InboxListFilter: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    /// Show only items that need a user decision.
    case actionable
    /// Show unread items.
    case unread
    /// Show all non-archived items.
    case all

    /// Stable identity used by SwiftUI controls.
    public var id: String { rawValue }
}
