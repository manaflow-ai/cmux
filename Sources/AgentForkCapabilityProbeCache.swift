import Foundation

actor AgentForkCapabilityProbeCache {
    private let maxEntries: Int
    private var valuesByKey: [String: Bool] = [:]
    private var expirationByKey: [String: TimeInterval] = [:]
    private var insertionOrder: [String] = []

    init(maxEntries: Int = 128) {
        self.maxEntries = max(1, maxEntries)
    }

    func value(for key: String, now: TimeInterval) -> Bool? {
        guard let expiration = expirationByKey[key] else { return nil }
        guard expiration > now else {
            removeValue(for: key)
            return nil
        }
        return valuesByKey[key]
    }

    func store(_ value: Bool, for key: String, now: TimeInterval, expiresAt: TimeInterval) {
        removeExpiredEntries(now: now)
        if valuesByKey[key] == nil {
            insertionOrder.append(key)
        }
        valuesByKey[key] = value
        expirationByKey[key] = expiresAt
        evictOldestEntriesIfNeeded()
    }

    private func removeExpiredEntries(now: TimeInterval) {
        let expiredKeys = expirationByKey.compactMap { entry in
            entry.value <= now ? entry.key : nil
        }
        for expiredKey in expiredKeys {
            removeValue(for: expiredKey)
        }
    }

    private func evictOldestEntriesIfNeeded() {
        while valuesByKey.count > maxEntries, let key = insertionOrder.first {
            removeValue(for: key)
        }
        if insertionOrder.count > maxEntries * 2 {
            insertionOrder = insertionOrder.filter { valuesByKey[$0] != nil }
        }
    }

    private func removeValue(for key: String) {
        valuesByKey.removeValue(forKey: key)
        expirationByKey.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }
}
