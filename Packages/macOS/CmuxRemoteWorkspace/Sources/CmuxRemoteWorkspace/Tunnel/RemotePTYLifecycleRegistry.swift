internal import Foundation

/// Bounded queue-confined registry of logical PTY attachment generations and retired tombstones.
struct RemotePTYLifecycleRegistry: Sendable {
    static let defaultCapacity = 256

    private let generationCapacity: Int
    private let retiredCapacity: Int
    private(set) var generations: [RemotePTYLifecycleKey: RemotePTYLifecycleGeneration] = [:]
    private var generationOrder: [RemotePTYLifecycleKey] = []
    private(set) var retiredKeys: Set<RemotePTYLifecycleKey> = []
    private var retiredOrder: [RemotePTYLifecycleKey] = []

    init(
        generationCapacity: Int = Self.defaultCapacity,
        retiredCapacity: Int = Self.defaultCapacity
    ) {
        self.generationCapacity = max(1, generationCapacity)
        self.retiredCapacity = max(1, retiredCapacity)
    }

    mutating func registerBridge(
        key: RemotePTYLifecycleKey,
        attachmentID: String,
        bridgeID: UUID
    ) throws {
        if retiredKeys.contains(key) {
            throw RemotePTYLifecycleError.intentionallyClosed
        }
        if var generation = generations[key] {
            guard generation.phase == .active else {
                retire(key)
                throw RemotePTYLifecycleError.intentionallyClosed
            }
            guard generation.attachmentID == attachmentID else {
                throw RemotePTYLifecycleError.attachmentMismatch
            }
            generation.bridgeIDs.insert(bridgeID)
            generations[key] = generation
            return
        }

        try makeGenerationSlot()
        generations[key] = RemotePTYLifecycleGeneration(
            attachmentID: attachmentID,
            phase: .active,
            bridgeIDs: [bridgeID],
            acceptedClient: false
        )
        generationOrder.append(key)
    }

    mutating func bridgeStopped(
        key: RemotePTYLifecycleKey,
        bridgeID: UUID,
        disposition: RemotePTYBridgeStopDisposition
    ) {
        guard var generation = generations[key] else { return }
        generation.bridgeIDs.remove(bridgeID)
        if disposition == .acceptedClient {
            generation.acceptedClient = true
        }
        guard generation.bridgeIDs.isEmpty, !generation.acceptedClient else {
            generations[key] = generation
            return
        }
        if generation.phase == .active {
            discardGeneration(key)
        } else {
            retire(key)
        }
    }

    mutating func requestIntentionalClose(
        sessionID: String
    ) -> [RemotePTYLifecycleKey: RemotePTYSessionLifecycle] {
        let normalizedSessionID = RemotePTYLifecycleKey(sessionID: sessionID, lifecycleID: "").sessionID
        var previous: [RemotePTYLifecycleKey: RemotePTYSessionLifecycle] = [:]
        for key in generationOrder where key.sessionID == normalizedSessionID {
            guard var generation = generations[key] else { continue }
            previous[key] = generation.phase
            generation.phase = .intentionalCleanupRequested
            generations[key] = generation
        }
        return previous
    }

    mutating func completeIntentionalClose(
        _ previous: [RemotePTYLifecycleKey: RemotePTYSessionLifecycle]
    ) {
        for key in previous.keys {
            guard var generation = generations[key] else { continue }
            generation.phase = .intentionallyClosed
            generations[key] = generation
        }
    }

    mutating func rollbackIntentionalClose(
        _ previous: [RemotePTYLifecycleKey: RemotePTYSessionLifecycle]
    ) {
        for (key, phase) in previous {
            guard var generation = generations[key] else { continue }
            generation.phase = phase
            generations[key] = generation
        }
    }

    func lifecycle(for key: RemotePTYLifecycleKey) -> RemotePTYSessionLifecycle {
        if retiredKeys.contains(key) { return .intentionallyClosed }
        return generations[key]?.phase ?? .active
    }

    mutating func acknowledge(_ key: RemotePTYLifecycleKey) {
        retire(key)
    }

    @discardableResult
    mutating func acknowledgeIfKnown(_ key: RemotePTYLifecycleKey) -> Bool {
        guard generations[key] != nil || retiredKeys.contains(key) else { return false }
        retire(key)
        return true
    }

    mutating func removeAll() {
        generations.removeAll(keepingCapacity: false)
        generationOrder.removeAll(keepingCapacity: false)
        retiredKeys.removeAll(keepingCapacity: false)
        retiredOrder.removeAll(keepingCapacity: false)
    }

    private mutating func makeGenerationSlot() throws {
        guard generations.count >= generationCapacity else { return }
        throw RemotePTYLifecycleError.capacityReached
    }

    private mutating func discardGeneration(_ key: RemotePTYLifecycleKey) {
        generations.removeValue(forKey: key)
        generationOrder.removeAll { $0 == key }
    }

    private mutating func retire(_ key: RemotePTYLifecycleKey) {
        discardGeneration(key)
        guard retiredKeys.insert(key).inserted else { return }
        retiredOrder.append(key)
        while retiredOrder.count > retiredCapacity {
            retiredKeys.remove(retiredOrder.removeFirst())
        }
    }
}
