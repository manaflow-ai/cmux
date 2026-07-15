import Foundation

actor AgentForkCapabilityProbeCache {
    private var valuesByKey: [String: Bool] = [:]
    private var expirationByKey: [String: TimeInterval] = [:]

    func value(for key: String, now: TimeInterval) -> Bool? {
        guard let expiration = expirationByKey[key] else { return nil }
        guard expiration > now else {
            valuesByKey.removeValue(forKey: key)
            expirationByKey.removeValue(forKey: key)
            return nil
        }
        return valuesByKey[key]
    }

    func store(_ value: Bool, for key: String, now: TimeInterval, expiresAt: TimeInterval) {
        let expiredKeys = expirationByKey.compactMap { entry in
            entry.value <= now ? entry.key : nil
        }
        for expiredKey in expiredKeys {
            valuesByKey.removeValue(forKey: expiredKey)
            expirationByKey.removeValue(forKey: expiredKey)
        }
        valuesByKey[key] = value
        expirationByKey[key] = expiresAt
    }
}
