import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

extension PortScanner {
    private static let deviceDirectoryPrefix = "/dev/"

    static func combinedCompleteness(
        _ lhs: PortScanCompleteness,
        _ rhs: PortScanCompleteness
    ) -> PortScanCompleteness {
        lhs == .complete && rhs == .complete ? .complete : .incomplete
    }

    /// Computes missing-port evidence from the identities that owned each
    /// previously published port. A process-tree scan may be incomplete for an
    /// unrelated child, but a listener PID that is still in the current
    /// ownership graph and whose own lsof result is complete still provides
    /// authoritative negative evidence. A live owner that fell out of an
    /// incomplete ownership graph remains incomplete rather than being
    /// mistaken for an exited listener.
    func missingPortCompletenessByKey<Key: Hashable & Sendable>(
        previousOwnersByKey: [Key: [Int: Set<AgentPIDProcessIdentity>]],
        observedOwnersByKey: [Key: [Int: Set<AgentPIDProcessIdentity>]],
        currentProcessIdentitiesByKey: [Key: Set<AgentPIDProcessIdentity>],
        processScopeCompletenessByKey: [Key: PortScanCompleteness],
        scannedKeys: Set<Key>,
        lsofScan: PortListenerScanResult,
        inspectedPIDs: Set<Int>
    ) -> [Key: [Int: PortScanCompleteness]] {
        var result: [Key: [Int: PortScanCompleteness]] = [:]
        var ownerEvidenceByKey: [Key: [AgentPIDProcessIdentity: PortScanCompleteness]] = [:]
        for key in scannedKeys {
            guard let previousOwners = previousOwnersByKey[key] else { continue }
            let observedOwners = observedOwnersByKey[key] ?? [:]
            let currentProcessIdentities = currentProcessIdentitiesByKey[key] ?? []
            let processScopeCompleteness = processScopeCompletenessByKey[key, default: .incomplete]
            for (port, owners) in previousOwners where observedOwners[port] == nil {
                guard !owners.isEmpty else { continue }
                let isAuthoritative = owners.allSatisfy { owner in
                    if let cached = ownerEvidenceByKey[key]?[owner] {
                        return cached == .complete
                    }
                    let pid = Int(owner.pid)
                    let evidence: PortScanCompleteness
                    if let currentIdentity = processIdentityProvider(pid_t(pid)) {
                        if currentIdentity != owner {
                            // A PID that now represents another process no
                            // longer owns this port, even if that replacement
                            // is not part of this scan's ownership graph.
                            evidence = .complete
                        } else {
                            // lsof can only prove a negative for a live PID
                            // when that PID is still in the current ownership
                            // scope. If the process graph dropped it, defer
                            // to the graph's completeness instead of allowing
                            // an incomplete fence to retire an active badge.
                            if currentProcessIdentities.contains(owner) {
                                evidence = inspectedPIDs.contains(pid)
                                    && lsofScan.completeness(for: [pid]) == .complete
                                    ? .complete
                                    : .incomplete
                            } else {
                                evidence = processScopeCompleteness == .complete
                                    ? .complete
                                    : .incomplete
                            }
                        }
                    } else {
                        evidence = processPresenceProvider(pid_t(pid)) == .absent
                            ? .complete
                            : .incomplete
                    }
                    ownerEvidenceByKey[key, default: [:]][owner] = evidence
                    return evidence == .complete
                }
                result[key, default: [:]][port] = isAuthoritative
                    ? .complete
                    : .incomplete
            }
        }
        return result
    }

    /// Merges trusted listener identities from a scan and discards identities
    /// for ports that the reconciler no longer publishes.
    static func updatePortOwners<Key: Hashable & Sendable>(
        _ ownersByKey: inout [Key: [Int: Set<AgentPIDProcessIdentity>]],
        observedOwnersByKey: [Key: [Int: Set<AgentPIDProcessIdentity>]],
        scannedKeys: Set<Key>,
        trackedKeys: Set<Key>,
        publishedSnapshot: [Key: [Int]]
    ) {
        ownersByKey = ownersByKey.filter { trackedKeys.contains($0.key) }
        for key in scannedKeys.intersection(trackedKeys) {
            var owners = ownersByKey[key] ?? [:]
            for (port, identities) in observedOwnersByKey[key] ?? [:] where !identities.isEmpty {
                owners[port] = identities
            }
            let publishedPorts = Set(publishedSnapshot[key] ?? [])
            owners = owners.filter { publishedPorts.contains($0.key) }
            if owners.isEmpty {
                ownersByKey.removeValue(forKey: key)
            } else {
                ownersByKey[key] = owners
            }
        }
    }

    /// Computes panel completeness from the process snapshot and only the PIDs owned by each TTY.
    static func panelCompletenessByKey(
        panelTTYs: [PanelKey: String],
        pidToTTY: [Int: String],
        psCompleteness: PortScanCompleteness,
        lsofScan: PortListenerScanResult?
    ) -> [PanelKey: PortScanCompleteness] {
        let pidsByTTY = pidToTTY.reduce(into: [String: Set<Int>]()) { result, item in
            result[canonicalTTYName(item.value), default: []].insert(item.key)
        }
        return panelTTYs.reduce(into: [:]) { result, item in
            let panelPIDs = pidsByTTY[canonicalTTYName(item.value)] ?? []
            let lsofCompleteness: PortScanCompleteness
            if panelPIDs.isEmpty {
                lsofCompleteness = .complete
            } else if let lsofScan {
                lsofCompleteness = lsofScan.completeness(for: panelPIDs)
            } else {
                lsofCompleteness = .incomplete
            }
            result[item.key] = combinedCompleteness(psCompleteness, lsofCompleteness)
        }
    }

    func expandAgentProcessTree(
        agentRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) async -> (
        values: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        guard !agentRootsByWorkspace.isEmpty else { return ([:], [:]) }
        let initialRootValidation = validateAgentRoots(agentRootsByWorkspace)
        guard !initialRootValidation.values.isEmpty else {
            return ([:], initialRootValidation.completenessByWorkspace)
        }
        let processScan = await readProcessParents()
        // A root recycled while the process table was read must not inherit
        // descendants from the captured graph.
        let postScanRootValidation = validateAgentRoots(agentRootsByWorkspace)
        var completenessByWorkspace = combineAgentCompleteness(
            initialRootValidation.completenessByWorkspace,
            postScanRootValidation.completenessByWorkspace,
            workspaceIds: Set(agentRootsByWorkspace.keys)
        )
        if processScan.completeness == .incomplete {
            for workspaceId in postScanRootValidation.values.keys {
                completenessByWorkspace[workspaceId] = .incomplete
            }
        }
        return (
            Self.agentProcessOwnership(
                processParents: processScan.values,
                rootsByWorkspace: postScanRootValidation.values
            ),
            completenessByWorkspace
        )
    }

    /// Traverses each captured `(PID, workspace)` pair at most once from already-validated roots.
    static func agentProcessOwnership(
        processParents: [Int: Int],
        rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) -> [Int: Set<UUID>] {
        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPID) in processParents {
            childrenByParent[parentPID, default: []].append(pid)
        }
        var ownershipByPID: [Int: Set<UUID>] = [:]
        var pending: [(pid: Int, workspaceId: UUID)] = []
        for (workspaceId, roots) in rootsByWorkspace {
            for root in roots {
                if ownershipByPID[root.pid, default: []].insert(workspaceId).inserted {
                    pending.append((root.pid, workspaceId))
                }
            }
        }
        var index = 0
        while index < pending.count {
            let (pid, workspaceId) = pending[index]
            index += 1
            for childPID in childrenByParent[pid] ?? [] {
                if ownershipByPID[childPID, default: []].insert(workspaceId).inserted {
                    pending.append((childPID, workspaceId))
                }
            }
        }
        return ownershipByPID
    }

    func validateAgentRoots(
        _ rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]
    ) -> (
        values: [UUID: Set<AgentPortRootIdentity>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        var validRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>] = [:]
        var completenessByWorkspace = rootsByWorkspace.mapValues { _ in PortScanCompleteness.complete }
        for (workspaceId, roots) in rootsByWorkspace {
            for root in roots where root.pid > 0 {
                guard let expectedIdentity = root.processIdentity else {
                    if processPresenceProvider(pid_t(root.pid)) != .absent {
                        completenessByWorkspace[workspaceId] = .incomplete
                    }
                    continue
                }
                guard let currentIdentity = processIdentityProvider(pid_t(root.pid)) else {
                    if processPresenceProvider(pid_t(root.pid)) != .absent {
                        completenessByWorkspace[workspaceId] = .incomplete
                    }
                    continue
                }
                guard currentIdentity == expectedIdentity else { continue }
                validRootsByWorkspace[workspaceId, default: []].insert(root)
            }
        }
        return (validRootsByWorkspace, completenessByWorkspace)
    }

    /// Captures stable identities and workspace completeness for the agent process graph.
    func captureAgentPIDIdentities(
        ownershipByPID: [Int: Set<UUID>],
        workspaceIds: Set<UUID>
    ) -> (
        ownershipByPID: [Int: Set<UUID>],
        identitiesByPID: [Int: AgentPIDProcessIdentity],
        incompletePIDs: Set<Int>,
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let capture = capturePIDIdentities(Set(ownershipByPID.keys))
        var retainedOwnership: [Int: Set<UUID>] = [:]
        var completenessByWorkspace = workspaceIds.reduce(into: [UUID: PortScanCompleteness]()) {
            $0[$1] = .complete
        }
        for (pid, workspaceOwnership) in ownershipByPID {
            guard capture.identitiesByPID[pid] != nil else {
                if capture.incompletePIDs.contains(pid) {
                    for workspaceId in workspaceOwnership { completenessByWorkspace[workspaceId] = .incomplete }
                }
                continue
            }
            retainedOwnership[pid] = workspaceOwnership
        }
        return (
            retainedOwnership,
            capture.identitiesByPID,
            capture.incompletePIDs,
            completenessByWorkspace
        )
    }

    func revalidateAgentPIDIdentities(
        ownershipByPID: [Int: Set<UUID>],
        identitiesByPID: [Int: AgentPIDProcessIdentity],
        workspaceIds: Set<UUID>
    ) -> (
        ownershipByPID: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let validation = revalidatePIDIdentities(identitiesByPID)
        var retainedOwnership: [Int: Set<UUID>] = [:]
        var completenessByWorkspace = workspaceIds.reduce(into: [UUID: PortScanCompleteness]()) {
            $0[$1] = .complete
        }
        for (pid, workspaceOwnership) in ownershipByPID {
            guard validation.validPIDs.contains(pid) else {
                if validation.incompletePIDs.contains(pid) {
                    for workspaceId in workspaceOwnership { completenessByWorkspace[workspaceId] = .incomplete }
                }
                continue
            }
            retainedOwnership[pid] = workspaceOwnership
        }
        return (retainedOwnership, completenessByWorkspace)
    }

    func capturePIDIdentities(
        _ pids: Set<Int>
    ) -> (identitiesByPID: [Int: AgentPIDProcessIdentity], incompletePIDs: Set<Int>) {
        var identitiesByPID: [Int: AgentPIDProcessIdentity] = [:]
        var incompletePIDs: Set<Int> = []
        for pid in pids {
            guard let identity = processIdentityProvider(pid_t(pid)), Int(identity.pid) == pid else {
                if processPresenceProvider(pid_t(pid)) != .absent { incompletePIDs.insert(pid) }
                continue
            }
            identitiesByPID[pid] = identity
        }
        return (identitiesByPID, incompletePIDs)
    }

    func revalidatePIDIdentities(
        _ identitiesByPID: [Int: AgentPIDProcessIdentity]
    ) -> (validPIDs: Set<Int>, incompletePIDs: Set<Int>) {
        var validPIDs: Set<Int> = []
        var incompletePIDs: Set<Int> = []
        for (pid, expectedIdentity) in identitiesByPID {
            guard let currentIdentity = processIdentityProvider(pid_t(pid)) else {
                if processPresenceProvider(pid_t(pid)) != .absent { incompletePIDs.insert(pid) }
                continue
            }
            if currentIdentity == expectedIdentity { validPIDs.insert(pid) }
        }
        return (validPIDs, incompletePIDs)
    }

    func revalidatePanelPIDOwnership(
        capturedPIDToTTY: [Int: String],
        capturedIdentitiesByPID: [Int: AgentPIDProcessIdentity],
        refreshedPIDToTTY: [Int: String]
    ) -> (values: [Int: String], incompletePIDs: Set<Int>) {
        let validation = revalidatePIDIdentities(capturedIdentitiesByPID)
        let values = capturedPIDToTTY.reduce(into: [Int: String]()) { result, entry in
            guard validation.validPIDs.contains(entry.key),
                  refreshedPIDToTTY[entry.key] == entry.value else { return }
            result[entry.key] = entry.value
        }
        return (values, validation.incompletePIDs)
    }

    /// Requires captured identities to remain owned in a fresh process graph before accepting PID continuity.
    func finalizeAgentPIDOwnership(
        rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>],
        capturedOwnershipByPID: [Int: Set<UUID>],
        capturedIdentitiesByPID: [Int: AgentPIDProcessIdentity],
        workspaceIds: Set<UUID>
    ) async -> (
        ownershipByPID: [Int: Set<UUID>],
        completenessByWorkspace: [UUID: PortScanCompleteness],
        rootPIDs: Set<Int>
    ) {
        guard !capturedOwnershipByPID.isEmpty else {
            let rootValidation = validateAgentRoots(rootsByWorkspace)
            return (
                [:],
                combineAgentCompleteness(
                    rootValidation.completenessByWorkspace,
                    [:],
                    workspaceIds: workspaceIds
                ),
                Self.agentRootPIDs(in: rootValidation.values)
            )
        }
        let currentProcessScan = await readProcessParents()
        let finalRootValidation = validateAgentRoots(rootsByWorkspace)
        let finalRootOwnership = Self.agentProcessOwnership(
            processParents: currentProcessScan.values,
            rootsByWorkspace: finalRootValidation.values
        )
        let rootFencedOwnership = capturedOwnershipByPID.reduce(into: [Int: Set<UUID>]()) { result, item in
            let retainedWorkspaces = item.value.intersection(finalRootOwnership[item.key] ?? [])
            if !retainedWorkspaces.isEmpty {
                result[item.key] = retainedWorkspaces
            }
        }
        let identityValidation = revalidateAgentPIDIdentities(
            ownershipByPID: rootFencedOwnership,
            identitiesByPID: capturedIdentitiesByPID,
            workspaceIds: workspaceIds
        )
        var completenessByWorkspace = combineAgentCompleteness(
            finalRootValidation.completenessByWorkspace,
            identityValidation.completenessByWorkspace,
            workspaceIds: workspaceIds
        )
        if currentProcessScan.completeness == .incomplete {
            for workspaceId in finalRootValidation.values.keys {
                completenessByWorkspace[workspaceId] = .incomplete
            }
        }
        // Roots that passed the final root validation and whose identity also
        // survived the revalidation above, for callers that must not badge an
        // agent root's own listeners while still tracking its general PID
        // ownership (e.g. completeness evidence). A PID that changed hands
        // between those two reads, or that was recycled by an unrelated
        // process earlier, is no longer the root and is not in this set.
        let identityValidatedRootPIDs = Self.agentRootPIDs(in: finalRootValidation.values)
            .intersection(identityValidation.ownershipByPID.keys)
        return (identityValidation.ownershipByPID, completenessByWorkspace, identityValidatedRootPIDs)
    }

    /// The union of tracked agent root PIDs across all scanned workspaces.
    static func agentRootPIDs(in rootsByWorkspace: [UUID: Set<AgentPortRootIdentity>]) -> Set<Int> {
        rootsByWorkspace.values.reduce(into: Set<Int>()) { result, roots in
            for root in roots {
                result.insert(root.pid)
            }
        }
    }

    func combineAgentCompleteness(
        _ lhs: [UUID: PortScanCompleteness],
        _ rhs: [UUID: PortScanCompleteness],
        workspaceIds: Set<UUID>
    ) -> [UUID: PortScanCompleteness] {
        workspaceIds.reduce(into: [:]) { result, workspaceId in
            result[workspaceId] = Self.combinedCompleteness(
                lhs[workspaceId, default: .complete],
                rhs[workspaceId, default: .complete]
            )
        }
    }

    func agentLsofCompleteness(
        ownershipByPID: [Int: Set<UUID>],
        lsofScan: PortListenerScanResult,
        workspaceIds: Set<UUID>
    ) -> [UUID: PortScanCompleteness] {
        var pidsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ownership) in ownershipByPID {
            for workspaceId in ownership {
                pidsByWorkspace[workspaceId, default: []].insert(pid)
            }
        }
        return workspaceIds.reduce(into: [:]) { result, workspaceId in
            result[workspaceId] = lsofScan.completeness(
                for: pidsByWorkspace[workspaceId] ?? []
            )
        }
    }

    /// Reads which processes sit on the listed terminals.
    ///
    /// - Parameter ttyList: Comma-separated terminal names, bare or full paths.
    /// - Returns: `[pid: canonical tty name]` and whether every terminal that
    ///   still exists was read.
    func readTerminalProcesses(
        ttyList: String
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        let ttyNames = Self.orderedTTYNames(in: ttyList)
        guard !ttyNames.isEmpty else { return ([:], .complete) }
        return await processTable.processesOnTerminals(named: ttyNames)
    }

    private static func orderedTTYNames(in ttyList: String) -> [String] {
        var seen: Set<String> = []
        return ttyList.split(separator: ",").compactMap { field in
            let name = String(field)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// Canonicalizes the shell's full device path (`/dev/ttys001`) and the bare
    /// terminal name (`ttys001`) to one identity used by every scan join.
    static func canonicalTTYName(_ ttyName: String) -> String {
        guard ttyName.hasPrefix(Self.deviceDirectoryPrefix) else { return ttyName }
        return String(ttyName.dropFirst(Self.deviceDirectoryPrefix.count))
    }

    /// Reads every live process's parent for agent process-tree expansion.
    func readProcessParents() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        await processTable.parentsByPID()
    }

    /// Reads listening TCP ports for each requested PID directly from the
    /// kernel. Every PID answers for itself, so one unreadable process no
    /// longer costs the whole scan its evidence.
    ///
    /// The callers are async, so this blocks a cooperative thread. That is safe
    /// at the current scale: the libproc calls measure about 1.25us per process,
    /// so a scan holds one thread for well under a millisecond every couple of
    /// seconds, and scans never overlap. Give it its own queue if that stops
    /// being true: if scans start running concurrently, or if a process with a
    /// very large descriptor table makes one scan slow, since the cost is per
    /// descriptor rather than per PID.
    func scanListeningPorts(pidsCsv: String) -> PortListenerScanResult {
        let requestedPIDs = Set(pidsCsv.split(separator: ",").compactMap { Int($0) })
        var portsByPID: [Int: Set<Int>] = [:]
        var incompletePIDs: Set<Int> = []

        for pid in requestedPIDs {
            switch listeningPortsProvider(pid_t(pid)) {
            case .ports(let ports):
                if !ports.isEmpty {
                    portsByPID[pid] = ports
                }
            case .denied, .unavailable:
                // An unprivileged caller cannot read a root-owned process's
                // sockets, and neither could lsof. Only a PID whose identity is
                // unreadable while it is still present counts as a miss, so a
                // panel behind the root `login` process can still retire ports.
                if processIdentityProvider(pid_t(pid)) == nil
                    && processPresenceProvider(pid_t(pid)) != .absent {
                    incompletePIDs.insert(pid)
                }
            }
        }

        return PortListenerScanResult(
            values: portsByPID,
            globallyComplete: true,
            incompletePIDs: incompletePIDs
        )
    }
}
