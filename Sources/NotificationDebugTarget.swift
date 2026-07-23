import Foundation

#if DEBUG
struct NotificationDebugTarget: Sendable {
    let workspaceId: UUID
    let surfaceId: UUID?
}
#endif
