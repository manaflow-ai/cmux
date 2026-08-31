import Foundation

struct MobileRPCConnectRouteState {
    /// Live connect/installed leases for this physical route. Exclusive
    /// admission keeps this at one; a make-before-break replacement dial may
    /// briefly hold a second lease alongside the installed session it will
    /// displace.
    var activeLeaseIDs: Set<UUID> = []
    var physicalCleanupTasks: [UUID: Task<Void, Never>] = [:]
}
