import Foundation

struct MobileRPCConnectRouteState {
    var activeLeaseID: UUID?
    var physicalCleanupTasks: [UUID: Task<Void, Never>] = [:]
}
