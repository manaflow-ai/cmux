import Foundation

enum MobileRPCConnectAdmission: Sendable, Equatable {
    case granted(MobileRPCConnectAttemptLease)
    case busy
    case cleanupBlocked
}

struct MobileRPCConnectRouteState {
    var activeLeaseID: UUID?
    var physicalCleanupTasks: [UUID: Task<Void, Never>] = [:]
}
