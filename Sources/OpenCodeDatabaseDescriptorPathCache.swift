import Darwin
import Foundation
import CMUXAgentLaunch

/// Caches successful descriptor scans by process generation and coalesces
/// simultaneous scans without blocking the live-index actor.
actor OpenCodeDatabaseDescriptorPathCache {
    static let shared = OpenCodeDatabaseDescriptorPathCache()

    private typealias CacheEntry = (
        path: String,
        cachedAt: Date,
        sequence: UInt64
    )
    private typealias PendingProbe = (
        id: UUID,
        task: Task<String?, Never>
    )

    private var entries: [String: CacheEntry] = [:]
    private var pendingProbes: [String: PendingProbe] = [:]
    private var sequence: UInt64 = 0
    private let maximumEntryCount = 64
    private let maximumConcurrentProbeCount = 2
    private let cacheTTL: TimeInterval = 60

    func resolve(
        processID: Int,
        environment: [String: String],
        reuseCompletedResult: Bool,
        probe: @escaping @Sendable () -> String?
    ) async -> String? {
        guard let processIdentity = AgentPIDProcessIdentity(pid: pid_t(processID)) else {
            return nil
        }
        let key = Self.cacheKey(
            processIdentity: processIdentity,
            environment: environment
        )
        if let pendingProbe = pendingProbes[key] {
            return await pendingProbe.task.value
        }
        let now = Date()
        if reuseCompletedResult,
           let entry = entries[key],
           now.timeIntervalSince(entry.cachedAt) < cacheTTL {
            return entry.path
        }
        entries.removeValue(forKey: key)
        guard pendingProbes.count < maximumConcurrentProbeCount else {
            return nil
        }

        let pendingProbe = PendingProbe(
            id: UUID(),
            task: Task.detached(priority: .utility, operation: probe)
        )
        pendingProbes[key] = pendingProbe
        let path = await pendingProbe.task.value
        if pendingProbes[key]?.id == pendingProbe.id {
            pendingProbes.removeValue(forKey: key)
        }
        guard let path,
              AgentPIDProcessIdentity(pid: pid_t(processID)) == processIdentity else {
            return nil
        }

        sequence &+= 1
        entries[key] = (
            path: path,
            cachedAt: Date(),
            sequence: sequence
        )
        while entries.count > maximumEntryCount,
              let oldestKey = entries.min(by: {
                  $0.value.sequence < $1.value.sequence
              })?.key {
            entries.removeValue(forKey: oldestKey)
        }
        return path
    }

    private static func cacheKey(
        processIdentity: AgentPIDProcessIdentity,
        environment: [String: String]
    ) -> String {
        var components = [
            String(processIdentity.pid),
            String(processIdentity.startSeconds),
            String(processIdentity.startMicroseconds),
        ]
        for key in [
            "HOME",
            "XDG_DATA_HOME",
            "OPENCODE_DB",
            "OPENCODE_DISABLE_CHANNEL_DB",
            OpenCodeSessionResolver.capturedDatabasePathEnvironmentKey,
        ] {
            components.append("\(key)=\(environment[key] ?? "")")
        }
        return components.joined(separator: "\u{0}")
    }
}
