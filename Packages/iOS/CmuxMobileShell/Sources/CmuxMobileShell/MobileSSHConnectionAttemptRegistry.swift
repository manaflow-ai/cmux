import Foundation

/// Tracks which asynchronous connection attempt currently owns a host.
struct MobileSSHConnectionAttemptRegistry {
    private var currentGenerationByHost: [UUID: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    mutating func begin(for hostID: UUID) -> UInt64 {
        nextGeneration &+= 1
        let generation = nextGeneration
        currentGenerationByHost[hostID] = generation
        return generation
    }

    mutating func invalidate(for hostID: UUID) {
        currentGenerationByHost[hostID] = nil
    }

    func isCurrent(_ generation: UInt64, for hostID: UUID) -> Bool {
        currentGenerationByHost[hostID] == generation
    }

    mutating func clearIfCurrent(_ generation: UInt64, for hostID: UUID) -> Bool {
        guard isCurrent(generation, for: hostID) else { return false }
        currentGenerationByHost[hostID] = nil
        return true
    }
}

struct MobileSSHConnectionAttemptSuperseded: Error {}
