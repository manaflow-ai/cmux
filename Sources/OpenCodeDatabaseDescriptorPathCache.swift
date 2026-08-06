import Darwin
import Foundation
import CMUXAgentLaunch

/// Caches successful descriptor scans by process generation and coalesces
/// simultaneous scans without blocking the live-index actor.
actor OpenCodeDatabaseDescriptorPathCache {
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
    private let maximumEntryCount: Int
    private let maximumConcurrentProbeCount: Int
    private var availableProbePermitCount: Int
    private var probePermitWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextProbePermitWaiterID: UInt64 = 0
    private var nextProbePermitWaiterToResume: UInt64 = 0
    private let cacheTTL: TimeInterval
    private let pendingProbeObserver: (@Sendable (_ reuseCompletedResult: Bool) -> Void)?
    private var isStopped = false

    init(
        maximumEntryCount: Int = 64,
        maximumConcurrentProbeCount: Int = 2,
        cacheTTL: TimeInterval = 60,
        pendingProbeObserver: (@Sendable (_ reuseCompletedResult: Bool) -> Void)? = nil
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumConcurrentProbeCount = max(1, maximumConcurrentProbeCount)
        self.cacheTTL = max(0, cacheTTL)
        self.pendingProbeObserver = pendingProbeObserver
        availableProbePermitCount = self.maximumConcurrentProbeCount
    }

    func resolve(
        processID: Int,
        environment: [String: String],
        reuseCompletedResult: Bool,
        probe: @escaping @Sendable () -> String?
    ) async -> String? {
        guard !isStopped else { return nil }
        guard let processIdentity = AgentPIDProcessIdentity(pid: pid_t(processID)) else {
            return nil
        }
        let key = Self.cacheKey(
            processIdentity: processIdentity,
            environment: environment
        )
        while true {
            if reuseCompletedResult,
               let pendingProbe = pendingProbes[key] {
                pendingProbeObserver?(true)
                let path = await pendingProbe.task.value
                guard !Task.isCancelled, !isStopped,
                      AgentPIDProcessIdentity(pid: pid_t(processID)) == processIdentity else {
                    return nil
                }
                return path
            }
            while !reuseCompletedResult,
                  let pendingProbe = pendingProbes[key] {
                pendingProbeObserver?(false)
                _ = await pendingProbe.task.value
                if pendingProbes[key]?.id == pendingProbe.id {
                    pendingProbes.removeValue(forKey: key)
                }
                guard !Task.isCancelled, !isStopped,
                      AgentPIDProcessIdentity(pid: pid_t(processID)) == processIdentity else {
                    return nil
                }
            }
            let now = Date()
            if reuseCompletedResult,
               let entry = entries[key],
               now.timeIntervalSince(entry.cachedAt) < cacheTTL {
                return entry.path
            }
            entries.removeValue(forKey: key)
            guard await acquireProbePermit() else { return nil }
            guard AgentPIDProcessIdentity(pid: pid_t(processID)) == processIdentity else {
                releaseProbePermit()
                return nil
            }
            if pendingProbes[key] != nil
                || reuseCompletedResult && entries[key] != nil {
                releaseProbePermit()
                continue
            }
            break
        }

        let pendingProbe = PendingProbe(
            id: UUID(),
            task: Task.detached(priority: .utility, operation: probe)
        )
        pendingProbes[key] = pendingProbe
        let path = await pendingProbe.task.value
        releaseProbePermit()
        let ownsCompletedProbe = pendingProbes[key]?.id == pendingProbe.id
        if ownsCompletedProbe {
            pendingProbes.removeValue(forKey: key)
        }
        guard !isStopped,
              let path,
              AgentPIDProcessIdentity(pid: pid_t(processID)) == processIdentity else {
            return nil
        }

        // A freshness-critical request may have retired this probe while it
        // was running. Its original caller can consume the result, but it must
        // not overwrite the newer probe's cache entry after actor reentrancy.
        guard ownsCompletedProbe else { return path }

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

    /// Cancels detached probes and releases queued callers when the owning
    /// live-index instance is torn down.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        entries.removeAll()
        for pendingProbe in pendingProbes.values {
            pendingProbe.task.cancel()
        }
        pendingProbes.removeAll()
        for continuation in probePermitWaiters.values {
            continuation.resume()
        }
        probePermitWaiters.removeAll()
    }

    private func acquireProbePermit() async -> Bool {
        guard !Task.isCancelled, !isStopped else { return false }
        if availableProbePermitCount > 0 {
            availableProbePermitCount -= 1
            return true
        }
        let waiterID = nextProbePermitWaiterID
        nextProbePermitWaiterID &+= 1
        await withCheckedContinuation { continuation in
            probePermitWaiters[waiterID] = continuation
        }
        guard !Task.isCancelled, !isStopped else {
            releaseProbePermit()
            return false
        }
        return true
    }

    private func releaseProbePermit() {
        guard !isStopped else { return }
        while nextProbePermitWaiterToResume < nextProbePermitWaiterID {
            let waiterID = nextProbePermitWaiterToResume
            nextProbePermitWaiterToResume &+= 1
            guard let continuation = probePermitWaiters.removeValue(
                forKey: waiterID
            ) else {
                continue
            }
            continuation.resume()
            return
        }
        availableProbePermitCount = min(
            maximumConcurrentProbeCount,
            availableProbePermitCount + 1
        )
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
