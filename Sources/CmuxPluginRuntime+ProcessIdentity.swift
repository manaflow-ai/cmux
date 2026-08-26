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
        generation: UUID = UUID(),
        processGroupID: pid_t? = nil,
        containmentMarkerURL: URL
    ) -> CmuxPluginProcessIdentity? {
        guard let startMicroseconds = Self.processStartMicroseconds(processID) else {
            return nil
        }
        let identity = CmuxPluginProcessIdentity(
            generation: generation,
            startMicroseconds: startMicroseconds,
            processGroupID: processGroupID ?? processID,
            containmentMarkerURL: containmentMarkerURL
        )
        lock.lock()
        processAuthorizations[processID] = .active(pluginID: pluginID)
        processAuthorizationIdentities[processID] = identity
        revokedPluginProcessGroups.removeValue(forKey: identity.processGroupID)
        revokedPluginContainmentMarkers.removeValue(forKey: containmentMarkerURL.path)
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
        if let storedIdentity = processAuthorizationIdentities[processID] {
            if revokedPluginProcessGroups.count >= 512 {
                revokedPluginProcessGroups.removeValue(
                    forKey: revokedPluginProcessGroups.keys.first!
                )
            }
            revokedPluginProcessGroups[storedIdentity.processGroupID] =
                storedIdentity.startMicroseconds
            if revokedPluginContainmentMarkers.count >= 512 {
                revokedPluginContainmentMarkers.removeValue(
                    forKey: revokedPluginContainmentMarkers.keys.first!
                )
            }
            revokedPluginContainmentMarkers[storedIdentity.containmentMarkerURL.path] = (
                storedIdentity.processGroupID,
                storedIdentity.startMicroseconds
            )
        }
        let detached = detachSubscriptionsLocked(pluginID: pluginID)
        lock.unlock()
        detached.subscriptions.forEach { $0.close() }
        if detached.removedActionReceiver {
            actionReadinessDidChange()
        }
    }

    /// Retires a root identity after exit, retaining a deny marker if an
    /// inherited descendant still holds the containment lease.
    func processDidExit(
        _ processID: pid_t,
        generation: UUID,
        containmentMarkerURL: URL? = nil
    ) {
        lock.lock()
        guard let storedIdentity = processAuthorizationIdentities[processID],
              storedIdentity.generation == generation else {
            lock.unlock()
            return
        }
        let authorization = processAuthorizations[processID]
        let pluginID: String?
        if case .active(let activePluginID)? = authorization {
            pluginID = activePluginID
        } else {
            pluginID = nil
        }
        lock.unlock()

        let markerURL = containmentMarkerURL ?? storedIdentity.containmentMarkerURL
        let markerIsHeld = CmuxPluginProcessContainment.anyProcessHoldsMarker(at: markerURL)

        lock.lock()
        guard processAuthorizationIdentities[processID] == storedIdentity else {
            lock.unlock()
            return
        }
        processAuthorizations.removeValue(forKey: processID)
        processAuthorizationIdentities.removeValue(forKey: processID)
        if let markerURL {
            if markerIsHeld {
                revokedPluginContainmentMarkers[markerURL.path] = (
                    storedIdentity.processGroupID,
                    storedIdentity.startMicroseconds
                )
            } else {
                revokedPluginContainmentMarkers.removeValue(forKey: markerURL.path)
                revokedPluginProcessGroups.removeValue(forKey: storedIdentity.processGroupID)
            }
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
        let identitySnapshot = processAuthorizationIdentities
        let revokedMarkerSnapshot = revokedPluginContainmentMarkers
        let hasRevokedGroups = !revokedPluginProcessGroups.isEmpty
        lock.unlock()
        guard !authorizationSnapshot.isEmpty
                || hasRevokedGroups
                || !revokedMarkerSnapshot.isEmpty else {
            return nil
        }
        if let resolved = processAuthorizationResolver.resolve(
            processID: processID,
            authorizations: authorizationSnapshot
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard processAuthorizations[resolved.rootProcessID] == resolved.authorization else {
                return .revoked
            }
            guard processIdentityIsCurrentLocked(rootProcessID: resolved.rootProcessID) else {
                return .revoked
            }
            return resolved.authorization
        }

        // A double-forked plugin child may no longer be reachable through its
        // parent chain, but it still holds the private launch marker. Resolve
        // that deterministic cmux-owned signal before treating the peer as an
        // ordinary external client.
        for (rootProcessID, identity) in identitySnapshot {
            guard CmuxPluginProcessContainment.processHoldsMarker(
                processID,
                at: identity.containmentMarkerURL
            ) else { continue }
            lock.lock()
            let authorization = processAuthorizations[rootProcessID]
            let isCurrent = processAuthorizationIdentities[rootProcessID] == identity
                && processIdentityIsCurrentLocked(rootProcessID: rootProcessID)
            lock.unlock()
            if isCurrent, let authorization {
                return authorization
            }
        }

        for markerPath in revokedMarkerSnapshot.keys {
            if CmuxPluginProcessContainment.processHoldsMarker(
                processID,
                at: URL(fileURLWithPath: markerPath)
            ) {
                return .revoked
            }
        }

        lock.lock()
        let knownGroup = Self.processGroupID(processID).map { groupID in
            if let revokedStart = revokedPluginProcessGroups[groupID] {
                let currentStart = Self.processStartMicroseconds(groupID)
                if currentStart != nil, currentStart != revokedStart {
                    revokedPluginProcessGroups.removeValue(forKey: groupID)
                    return false
                }
                if Darwin.kill(-groupID, 0) == 0 || errno == EPERM {
                    return true
                }
                revokedPluginProcessGroups.removeValue(forKey: groupID)
            }
            return processAuthorizationIdentities.values.contains { identity in
                identity.processGroupID == groupID
            }
        } ?? false
        lock.unlock()
        return knownGroup ? .revoked : nil
    }

    /// Classifies a peer using the supervised process resolver and marker.
    /// Unknown peers remain subject to the socket server's existing mode
    /// authorization; only a positively identified plugin is restricted.
    func socketPeerPolicy(
        forProcess processID: pid_t?,
        isEventStreamRequest: Bool
    ) -> CmuxPluginSocketPeerPolicy {
        guard let processID else { return .standard }
        if let authorization = processAuthorization(forProcess: processID) {
            return Self.socketPeerPolicy(
                processAuthorization: authorization,
                isEventStreamRequest: isEventStreamRequest
            )
        }
        return .standard
    }

    /// Checks a resolved root while ``lock`` is held. Socket stream
    /// registration uses the same check to close the PID-reuse window.
    func processIdentityIsCurrentLocked(rootProcessID: pid_t) -> Bool {
        guard let identity = processAuthorizationIdentities[rootProcessID],
              Self.processStartMicroseconds(rootProcessID)
                == identity.startMicroseconds else {
            return false
        }
        return true
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
        if let info = processBSDInfo(processID) {
            return pid_t(info.pbi_ppid)
        }
        // Match the control-socket ancestry fallback when proc_pidinfo is
        // transiently unavailable; otherwise a plugin peer could be admitted
        // generically while this narrower resolver returns nil.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        return info.kp_eproc.e_ppid
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
        if let info = processBSDInfo(processID) {
            return Int64(info.pbi_start_tvsec) * 1_000_000
                + Int64(info.pbi_start_tvusec)
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else {
            return nil
        }
        return Int64(info.kp_proc.p_starttime.tv_sec) * 1_000_000
            + Int64(info.kp_proc.p_starttime.tv_usec)
    }

    private static func processGroupID(_ processID: Int32) -> pid_t? {
        let group = getpgid(processID)
        return group > 1 ? group : nil
    }
}
