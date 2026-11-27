import Foundation

enum NotificationFeedHistoryMutation: Sendable {
    case record(NotificationFeedHistoryRecord, supersededIDs: Set<UUID>)
    case reconcileActive([NotificationFeedHistoryRecord])
    case markReadIDs(Set<UUID>)
    case markReadWorkspace(UUID)
    case markReadSurface(tabId: UUID, surfaceId: UUID?)
    case markAllRead
    case markUnreadIDs(Set<UUID>)
    case rebindSurface(sourceTabId: UUID, destinationTabId: UUID, surfaceId: UUID)
}
