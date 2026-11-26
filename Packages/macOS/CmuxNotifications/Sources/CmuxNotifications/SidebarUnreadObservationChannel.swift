import Foundation

/// Selects the unread projection observed by one cancellation token.
enum SidebarUnreadObservationChannel: Sendable {
    case snapshot
    case summary
    case surface(ownerId: UUID)
}
