import CmuxExtensionKit
import Darwin

extension CmuxPluginRuntime {
    /// Records the PID of a supervised plugin child so its socket requests can
    /// be required to carry the matching plugin token.
    func registerProcess(_ processID: pid_t, for pluginID: String) {
        lock.lock()
        processAuthorizations[processID] = .active(pluginID: pluginID)
        lock.unlock()
    }

    /// Revokes a supervised child while retaining a deny-only lineage marker
    /// until the operating system reports that the root process has exited.
    func revokeProcess(_ processID: pid_t) {
        lock.lock()
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
    func processDidExit(_ processID: pid_t) {
        lock.lock()
        let authorization = processAuthorizations.removeValue(forKey: processID)
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
            return nil
        }
        return resolved.authorization
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
        guard result == expectedSize else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
