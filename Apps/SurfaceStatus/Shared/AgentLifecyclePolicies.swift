import Foundation

struct DirectStatusProcessIdentity: Equatable, Sendable {
    static let birthTolerance: TimeInterval = 1.0

    let recordedStartedAt: TimeInterval

    func matches(actualStartedAt: TimeInterval) -> Bool {
        recordedStartedAt.isFinite
            && actualStartedAt.isFinite
            && abs(recordedStartedAt - actualStartedAt) <= Self.birthTolerance
    }
}

struct NativeProcessIdentity: Equatable, Sendable {
    let seconds: Int64
    let microseconds: Int64

    func matches(recordedSeconds: Int64?, recordedMicroseconds: Int64?) -> Bool {
        guard let recordedSeconds,
              let recordedMicroseconds,
              recordedSeconds >= 0,
              (0..<1_000_000).contains(recordedMicroseconds) else {
            return false
        }
        return seconds == recordedSeconds && microseconds == recordedMicroseconds
    }
}

enum LifecycleSessionOwnership {
    static let claudeFallbackWindow: TimeInterval = 10.0
    static let futureTolerance: TimeInterval = 1.0

    /// A present active map is authoritative, including when empty. Its keys
    /// are UUID-normalized so case differences cannot detach surface ownership.
    /// Claude may use a brief process-verified fallback only while the map is
    /// absent and cmux has not yet persisted the owner map.
    static func isEligible(
        agentID: String,
        sessionID: String,
        surfaceID: UUID,
        activeSessionsBySurface: [String: String]?,
        updatedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        if let activeSessionsBySurface {
            return activeSessionsBySurface.first {
                UUID(uuidString: $0.key) == surfaceID
            }?.value == sessionID
        }
        guard agentID == "claude",
              let updatedAt,
              updatedAt.isFinite,
              updatedAt <= now + futureTolerance,
              now - updatedAt <= claudeFallbackWindow else {
            return agentID != "claude"
        }
        return true
    }
}
