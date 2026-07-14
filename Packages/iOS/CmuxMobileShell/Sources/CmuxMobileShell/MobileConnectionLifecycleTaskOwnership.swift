import Foundation

struct MobileConnectionLifecycleTaskOwnership {
    var activeUsesCachedReconnect = false
    var activeReconnectFence: SynchronousGenerationBoundary?
    var activeReconnectProgress: StoredMacReconnectProgress?
    var primaryRetiredTask: Task<Void, Never>?
    var primaryRetiredGeneration: UInt64 = 0
    var primaryRetiredReconnectDemand: RetiredStoredMacReconnectDemand?
    var cachedRetiredTask: Task<Void, Never>?
    var cachedRetiredGeneration: UInt64 = 0
    var cachedRetiredReconnectDemand: RetiredStoredMacReconnectDemand?
    var pendingCachedReconnectPersistence: DeferredStoredMacReconnectPersistence?
    var deferredPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    var deferredPersistenceOperations: [UUID: DeferredStoredMacReconnectPersistence] = [:]

    var retiredCarriesReconnectDemand: Bool {
        primaryRetiredReconnectDemand != nil || cachedRetiredReconnectDemand != nil
    }

    mutating func clearRetiredReconnectDemand() {
        primaryRetiredReconnectDemand = nil
        cachedRetiredReconnectDemand = nil
    }

    mutating func clearRetiredReconnectDemand(forgetting macDeviceIDs: Set<String>) {
        if primaryRetiredReconnectDemand?.targetsAny(macDeviceIDs) == true {
            primaryRetiredReconnectDemand = nil
        }
        if cachedRetiredReconnectDemand?.targetsAny(macDeviceIDs) == true {
            cachedRetiredReconnectDemand = nil
        }
    }
}
