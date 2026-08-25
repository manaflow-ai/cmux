import CmuxExtensionKit
import Darwin
import Foundation

extension CmuxPluginRuntime {
    /// Records the PID of a supervised plugin child so its socket requests can
    /// be required to carry the matching plugin token.
    @discardableResult
    func registerProcess(
        _ processID: pid_t,
        for pluginID: String,
        generation: UUID = UUID()
    ) -> CmuxPluginProcessIdentity {
        let identity = CmuxPluginProcessIdentity(
            generation: generation,
            startMicroseconds: Self.processStartMicroseconds(processID)
        )
        lock.lock()
        processAuthorizations[processID] = .active(pluginID: pluginID)
        processAuthorizationIdentities[processID] = identity
        lock.unlock()
        return identity
    }

    /// Revokes a supervised child while retaining a deny-only lineage marker
    /// until the operating system reports that the root process has exited.
    func revokeProcess(_ processID: pid_t, identity: CmuxPluginProcessIdentity? = nil) {
        lock.lock()
        guard identity == nil || processAuthorizationIdentities[processID] == identity else {
            lock.unlock()
            return
        }
        let pluginID: String?
        if case .active(let activePluginID)? = processAuthorizations[processID] {
            pluginID = activePluginID
            processAuthorizations[processID] = .revoked
        } else {
            pluginID = nil
        }
        let detached = detachSubscriptionsLocked(pluginID: pluginID)
        lock.unlock()
        detached.subscriptions.forEach { $0.close() }
        if detached.removedActionReceiver {
            actionReadinessDidChange()
        }
    }

    /// Removes a process-lineage marker after its root has exited.
    func processDidExit(_ processID: pid_t, generation: UUID) {
        lock.lock()
        guard processAuthorizationIdentities[processID]?.generation == generation else {
            lock.unlock()
            return
        }
        let authorization = processAuthorizations.removeValue(forKey: processID)
        processAuthorizationIdentities.removeValue(forKey: processID)
        let pluginID: String?
        if case .active(let activePluginID)? = authorization {
            pluginID = activePluginID
        } else {
            pluginID = nil
        }
        let detached = detachSubscriptionsLocked(pluginID: pluginID)
        lock.unlock()
        detached.subscriptions.forEach { $0.close() }
        if detached.removedActionReceiver {
            actionReadinessDidChange()
        }
    }

    /// Returns the supervised plugin authorization associated with a peer PID.
    func processAuthorization(forProcess processID: pid_t?) -> CmuxPluginProcessAuthorization? {
        guard let processID else { return nil }
        lock.lock()
        let authorizationSnapshot = processAuthorizations
        lock.unlock()
        guard let resolved = processAuthorizationResolver.resolve(
            processID: processID,
            authorizations: authorizationSnapshot
        ) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard processAuthorizations[resolved.rootProcessID] == resolved.authorization else {
            return .revoked
        }
        guard processIdentityIsCurrentLocked(rootProcessID: resolved.rootProcessID) else {
            // The peer reached a supervised root, but its process instance no
            // longer matches. Treat it as revoked rather than an ordinary cmux
            // client so it cannot fall through to unrestricted socket commands.
            return .revoked
        }
        return resolved.authorization
    }

    /// Checks a resolved root while ``lock`` is held. Socket stream
    /// registration uses the same check to close the PID-reuse window.
    func processIdentityIsCurrentLocked(rootProcessID: pid_t) -> Bool {
        guard let identity = processAuthorizationIdentities[rootProcessID],
              let expectedStart = identity.startMicroseconds else {
            return false
        }
        return Self.processStartMicroseconds(rootProcessID) == expectedStart
    }

    /// Detaches a plugin's streams while the caller holds ``lock``.
    private func detachSubscriptionsLocked(
        pluginID: String?
    ) -> (subscriptions: [CmuxEventSubscription], removedActionReceiver: Bool) {
        guard let pluginID else { return ([], false) }
        let subscriptions = subscriptionsByPluginID.removeValue(forKey: pluginID)
            .map { Array($0.values) } ?? []
        let actionSubscriptions = actionSubscriptionIDsByPluginID.removeValue(forKey: pluginID)
        return (subscriptions, actionSubscriptions?.isEmpty == false)
    }

    /// A sendable Darwin lookup closure supplied to the package authorization
    /// resolver during composition. The implementation remains private to
    /// this file so the app exposes only the dependency boundary.
    nonisolated static let parentProcessLookup:
        CmuxPluginProcessAuthorizationResolver.ParentProcessLookup = { processID in
            CmuxPluginRuntime.parentProcessID(processID)
        }

    private static func parentProcessID(_ processID: Int32) -> Int32? {
        guard let info = processBSDInfo(processID) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func processBSDInfo(_ processID: Int32) -> proc_bsdinfo? {
        guard processID > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        return result == expectedSize ? info : nil
    }

    static func processStartMicroseconds(_ processID: Int32) -> Int64? {
        guard let info = processBSDInfo(processID) else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000
            + Int64(info.pbi_start_tvusec)
    }
}
