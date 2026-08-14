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
        let subscriptions = pluginID.flatMap { subscriptionsByPluginID.removeValue(forKey: $0) }
        let removedActionReceiver: Bool
        if let pluginID,
           let actionSubscriptions = actionSubscriptionIDsByPluginID.removeValue(forKey: pluginID) {
            removedActionReceiver = !actionSubscriptions.isEmpty
        } else {
            removedActionReceiver = false
        }
        lock.unlock()
        subscriptions?.values.forEach { $0.close() }
        if removedActionReceiver {
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
        let subscriptions = pluginID.flatMap { subscriptionsByPluginID.removeValue(forKey: $0) }
        let removedActionReceiver: Bool
        if let pluginID,
           let actionSubscriptions = actionSubscriptionIDsByPluginID.removeValue(forKey: pluginID) {
            removedActionReceiver = !actionSubscriptions.isEmpty
        } else {
            removedActionReceiver = false
        }
        lock.unlock()
        subscriptions?.values.forEach { $0.close() }
        if removedActionReceiver {
            actionReadinessDidChange()
        }
    }

    /// Returns the supervised plugin authorization associated with a peer PID.
    func processAuthorization(forProcess processID: pid_t?) -> CmuxPluginProcessAuthorization? {
        guard let processID else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return Self.processAuthorization(for: processID, in: processAuthorizations)
    }

    /// Walks a peer's ancestry to find an active or revoked plugin root.
    /// Descendants intentionally inherit the root's state, while an orphaned
    /// process stops matching once its supervised ancestor has exited.
    static func processAuthorization(
        for processID: pid_t,
        in authorizations: [pid_t: CmuxPluginProcessAuthorization]
    ) -> CmuxPluginProcessAuthorization? {
        var current = processID
        var visited = Set<pid_t>()
        for _ in 0..<32 {
            guard visited.insert(current).inserted else { return nil }
            if let authorization = authorizations[current] { return authorization }
            guard let parent = parentProcessID(current), parent > 0, parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func parentProcessID(_ processID: pid_t) -> pid_t? {
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
