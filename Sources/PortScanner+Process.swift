import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

extension PortScanner {
    static let processScanTimeout: TimeInterval = 3
    /// Bounds the retry loop that drops terminals `ps` reports as gone, so a
    /// pty churning during a scan cannot spin the scanner.
    static let maximumProcessScanAttempts = 3
    private static let deviceDirectoryPrefix = "/dev/"
    private static let missingDeviceDiagnosticSuffix = ": No such file or directory"

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
        lsofScan: PortLsofScanResult,
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
        lsofScan: PortLsofScanResult?
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
        let processScan = await runAllProcesses()
        // A root recycled during `ps` must not inherit descendants from the captured graph.
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
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        guard !capturedOwnershipByPID.isEmpty else {
            let rootValidation = validateAgentRoots(rootsByWorkspace)
            return (
                [:],
                combineAgentCompleteness(
                    rootValidation.completenessByWorkspace,
                    [:],
                    workspaceIds: workspaceIds
                )
            )
        }
        let currentProcessScan = await runAllProcesses()
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
        return (identityValidation.ownershipByPID, completenessByWorkspace)
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
        lsofScan: PortLsofScanResult,
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

    func runPS(ttyList: String) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        var remaining = Self.orderedTTYNames(in: ttyList)
        guard !remaining.isEmpty else { return ([:], .complete) }

        for attempt in 0..<Self.maximumProcessScanAttempts {
            let result = await commandRunner.run(
                directory: "/",
                executable: "/bin/ps",
                arguments: ["-t", remaining.joined(separator: ","), "-o", "pid=,tty="],
                timeout: Self.processScanTimeout
            )

            var mapping: [Int: String] = [:]
            var parsedEveryRow = true
            for line in (result.stdout ?? "").split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 2, let pid = Int(parts[0]), pid > 0 else {
                    parsedEveryRow = false
                    continue
                }
                mapping[pid] = Self.canonicalTTYName(String(parts[1]))
            }
            if Self.isCompletePSResult(result) && parsedEveryRow {
                return (mapping, .complete)
            }

            let vanished = Self.vanishedTTYNames(
                inStderr: result.stderr,
                requested: Set(remaining)
            )
            guard !vanished.isEmpty else { return (mapping, .incomplete) }
            remaining.removeAll { vanished.contains($0) }
            // Every terminal is gone, which is authoritative emptiness rather
            // than a failed scan: no process can be attached to a freed pty.
            // Emptiness outranks the retry budget so the verdict does not
            // depend on which attempt the last pty happened to close during.
            guard !remaining.isEmpty else { return ([:], .complete) }
            guard attempt < Self.maximumProcessScanAttempts - 1 else {
                return (mapping, .incomplete)
            }
        }
        return ([:], .incomplete)
    }

    private static func orderedTTYNames(in ttyList: String) -> [String] {
        var seen: Set<String> = []
        return ttyList.split(separator: ",").compactMap { field in
            let name = String(field)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// Terminals that `ps` reported as no longer present on the filesystem.
    ///
    /// BSD `ps` abandons the whole `-t` query when any listed device is gone,
    /// naming each one on stderr and writing nothing to stdout. Retrying
    /// without them keeps one closed pty from erasing every other panel's
    /// evidence. Only ENOENT is treated as absence; any other diagnostic
    /// leaves the scan incomplete so ports are retained rather than dropped.
    ///
    /// Matching the English `strerror(ENOENT)` suffix is safe regardless of the
    /// user's locale: Darwin libc ships no localized message catalogs, so
    /// `ps` emits this exact text even under a non-English `LC_ALL`.
    static func vanishedTTYNames(inStderr stderr: String?, requested: Set<String>) -> Set<String> {
        guard let stderr, !stderr.isEmpty else { return [] }
        // Direct callers can supply either `ttys1` or `/dev/ttys1`; match on
        // the canonical device name either form names.
        let requestedByDeviceName = requested.reduce(into: [String: Set<String>]()) { result, name in
            result[Self.canonicalTTYName(name), default: []].insert(name)
        }
        var vanished: Set<String> = []
        for line in stderr.split(separator: "\n") {
            guard line.hasSuffix(Self.missingDeviceDiagnosticSuffix) else { continue }
            let paths = String(line.dropLast(Self.missingDeviceDiagnosticSuffix.count))
            // For a name that does not already start with `tty`, `ps` stats
            // both candidate devices and names them in one diagnostic:
            // "ps: /dev/ttyfoo and /dev/foo: No such file or directory".
            for path in paths.components(separatedBy: " and ") {
                guard let devicePrefix = path.range(of: Self.deviceDirectoryPrefix) else { continue }
                let deviceName = String(path[devicePrefix.upperBound...])
                if let names = requestedByDeviceName[deviceName] {
                    vanished.formUnion(names)
                }
            }
        }
        return vanished
    }

    /// Canonicalizes the shell's full device path and `ps`'s abbreviated TTY
    /// field to one identity used by every scan join.
    static func canonicalTTYName(_ ttyName: String) -> String {
        guard ttyName.hasPrefix(Self.deviceDirectoryPrefix) else { return ttyName }
        return String(ttyName.dropFirst(Self.deviceDirectoryPrefix.count))
    }

    func runAllProcesses() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        let result = await commandRunner.run(
            directory: "/",
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,ppid="],
            timeout: Self.processScanTimeout
        )

        var mapping: [Int: Int] = [:]
        var parsedEveryRow = true
        for line in (result.stdout ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  let pid = Int(parts[0]),
                  let parentPid = Int(parts[1]),
                  pid > 0,
                  parentPid >= 0 else {
                parsedEveryRow = false
                continue
            }
            mapping[pid] = parentPid
        }
        let complete = Self.isComplete(result) && parsedEveryRow
        return (mapping, complete ? .complete : .incomplete)
    }

    func runLsof(pidsCsv: String) async -> PortLsofScanResult {
        let pids = pidsCsv.split(separator: ",").compactMap { Int($0) }
        guard pids.count > 256 else { return await runLsofChunk(pidsCsv: pidsCsv) }
        var values: [Int: Set<Int>] = [:]
        var incomplete: Set<Int> = []
        var complete = true
        for chunk in Self.lsofPIDChunks(pids) {
            let result = await runLsofChunk(pidsCsv: chunk.map(String.init).joined(separator: ","))
            for (pid, ports) in result.values { values[pid, default: []].formUnion(ports) }
            incomplete.formUnion(result.incompletePIDs)
            complete = complete && result.globallyComplete
        }
        return PortLsofScanResult(values: values, globallyComplete: complete, incompletePIDs: incomplete)
    }

    // Keep the complete argv entry below the platform's practical exec limit.
    // The chunk builder below accounts for separators as it appends, so it
    // never copies or re-serializes the growing prefix.
    static let lsofArgumentByteBudget = 32 * 1024
    static let lsofArgumentOverhead = 256

    static func lsofPIDChunks(_ pids: [Int]) -> [[Int]] {
        guard !pids.isEmpty else { return [] }
        var chunks: [[Int]] = []
        var chunk: [Int] = []
        var chunkBytes = 0
        for pid in pids {
            let pidBytes = String(pid).utf8.count
            let additionalBytes = chunk.isEmpty ? pidBytes : pidBytes + 1
            if !chunk.isEmpty,
               chunkBytes + additionalBytes + lsofArgumentOverhead > lsofArgumentByteBudget
            {
                chunks.append(chunk)
                chunk = []
                chunkBytes = 0
            }
            let separatorBytes = chunk.isEmpty ? 0 : 1
            chunk.append(pid)
            chunkBytes += pidBytes + separatorBytes
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func runLsofChunk(pidsCsv: String) async -> PortLsofScanResult {
        let result = await commandRunner.run(
            directory: "/",
            executable: "/usr/sbin/lsof",
            // A PID-scoped TCP query does not depend on filesystem mount
            // metadata. Suppress warning-class diagnostics such as lsof's
            // Time Machine `can't stat()` warning so unrelated mounts cannot
            // make every port miss permanently incomplete.
            arguments: ["-nP", "-w", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"],
            timeout: Self.processScanTimeout
        )

        var portsByPID: [Int: Set<Int>] = [:]
        var currentPID: Int?
        var parsedEveryRow = true
        var parseIncompletePIDs: Set<Int> = []
        for line in (result.stdout ?? "").split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                guard let pid = Int(line.dropFirst()), pid > 0 else {
                    currentPID = nil
                    parsedEveryRow = false
                    continue
                }
                currentPID = pid
            case "n":
                guard let currentPID else {
                    parsedEveryRow = false
                    continue
                }
                var name = String(line.dropFirst())
                if let arrow = name.range(of: "->") {
                    name = String(name[..<arrow.lowerBound])
                }
                guard let colon = name.lastIndex(of: ":") else {
                    parseIncompletePIDs.insert(currentPID)
                    continue
                }
                let portText = name[name.index(after: colon)...]
                guard portText.allSatisfy(\.isNumber),
                      let port = Int(portText),
                      port > 0,
                      port <= 65_535 else {
                    parseIncompletePIDs.insert(currentPID)
                    continue
                }
                portsByPID[currentPID, default: []].insert(port)
            case "f":
                if line.dropFirst().isEmpty {
                    if let currentPID {
                        parseIncompletePIDs.insert(currentPID)
                    } else {
                        parsedEveryRow = false
                    }
                }
            default:
                if let currentPID {
                    parseIncompletePIDs.insert(currentPID)
                } else {
                    parsedEveryRow = false
                }
            }
        }
        // lsof exits 1 both for "no selected files" and when one requested PID
        // disappears. Keep the failure scoped to the PIDs that can no longer be
        // inspected so unrelated workspaces can still consume complete evidence.
        let requestedPIDs = Set(pidsCsv.split(separator: ",").compactMap { Int($0) })
        var incompletePIDs = parseIncompletePIDs
        incompletePIDs.formUnion(requestedPIDs.filter {
            processIdentityProvider(pid_t($0)) == nil
                && processPresenceProvider(pid_t($0)) != .absent
        })
        let globallyComplete = result.executionError == nil
            && !result.timedOut
            && (result.exitStatus == 0 || result.exitStatus == 1)
            && (result.stderr ?? "").isEmpty
            && parsedEveryRow
        return PortLsofScanResult(
            values: portsByPID,
            globallyComplete: globallyComplete,
            incompletePIDs: incompletePIDs
        )
    }

    private static func isComplete(_ result: CommandResult) -> Bool {
        result.executionError == nil
            && !result.timedOut
            && result.exitStatus == 0
            && (result.stderr ?? "").isEmpty
    }

    private static func isCompletePSResult(_ result: CommandResult) -> Bool {
        // BSD ps exits 1 when a valid selector matches no processes.
        return isComplete(result)
            || (result.executionError == nil
                && !result.timedOut
                && result.exitStatus == 1
                && (result.stdout ?? "").isEmpty
                && (result.stderr ?? "").isEmpty)
    }
}
