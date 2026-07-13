import Foundation

enum MobileRPCConnectRouteState {
    case active(id: UUID, abandonedAttempts: Int)
    case released(id: UUID, abandonedAttempts: Int)
    case hardGated(id: UUID, abandonedAttempts: Int, expiresAt: UInt64)
}
