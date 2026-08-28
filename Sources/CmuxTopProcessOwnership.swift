import Darwin
import Foundation

/// Evidence used when a terminal TTY is observed in a top snapshot.
enum CmuxTopProcessOwnershipReason: String, Sendable {
    case explicitScope = "cmux-explicit-scope"
    case descendant = "cmux-descendant"
    case processGroup = "cmux-process-group"
    case sameTTYUnproven = "same-tty-unproven"
    case conflictingScope = "conflicting-cmux-scope"
    case webViewRoot = "webview-root-pid"
}

/// Separates processes observed on a terminal from processes cmux can prove it owns.
struct CmuxTopTerminalProcessOwnership: Sendable {
    let explicitScopeProcessIDs: Set<Int>
    let observedTTYProcessIDs: Set<Int>
    let ownedTTYProcessIDs: Set<Int>
    let ambiguousTTYProcessIDs: Set<Int>
    let ownedProcessIDs: Set<Int>
    let rootProcessIDs: Set<Int>
    let reasonByProcessID: [Int: String]

    var hasAmbiguousTTYProcesses: Bool {
        !ambiguousTTYProcessIDs.isEmpty
    }

    func payload() -> [String: Any] {
        let reasons = Dictionary(uniqueKeysWithValues: reasonByProcessID
            .sorted { $0.key < $1.key }
            .map { (String($0.key), $0.value) })
        let ambiguousReasons = Set(ambiguousTTYProcessIDs.compactMap { reasonByProcessID[$0] }).sorted()
        let ambiguousReason: Any
        if ambiguousReasons.isEmpty {
            ambiguousReason = NSNull()
        } else if ambiguousReasons.count == 1, let reason = ambiguousReasons.first {
            ambiguousReason = reason
        } else {
            ambiguousReason = "multiple-evidence"
        }
        let status: String
        if !ambiguousTTYProcessIDs.isEmpty {
            status = "ambiguous"
        } else if !ownedProcessIDs.isEmpty {
            status = "proven"
        } else {
            status = "no-tty"
        }
        return [
            "model": "scope-or-lineage",
            "status": status,
            "observed_pids": observedTTYProcessIDs.sorted(),
            "owned_pids": ownedTTYProcessIDs.sorted(),
            "ambiguous_pids": ambiguousTTYProcessIDs.sorted(),
            "explicit_scope_pids": explicitScopeProcessIDs.sorted(),
            "reason_by_pid": reasons,
            "ambiguous_reason": ambiguousReason,
            "ambiguous_reasons": ambiguousReasons
        ]
    }
}

extension CmuxTopProcessSnapshot {
    /// Returns ownership evidence for one terminal surface's TTY.
    ///
    /// The TTY is only an observation. A process that was reparented to PID 1
    /// can retain the controlling TTY after leaving cmux's tree, so TTY alone
    /// must never promote a process to a surface root.
    func terminalProcessOwnership(
        surfaceID: UUID?,
        ttyName: String?,
        applicationPID: Int = Int(Darwin.getpid())
    ) -> CmuxTopTerminalProcessOwnership {
        let ttyDevice = ttyName.flatMap(Self.deviceIdentifier(forTTYName:))
        return terminalProcessOwnership(
            surfaceID: surfaceID,
            ttyDevice: ttyDevice,
            applicationPID: applicationPID
        )
    }

    /// Device-based overload keeps ownership tests independent of a live path.
    func terminalProcessOwnership(
        surfaceID: UUID?,
        ttyDevice: Int64?,
        applicationPID: Int = Int(Darwin.getpid())
    ) -> CmuxTopTerminalProcessOwnership {
        let observedTTYProcessIDs = ttyDevice.map { pids(forTTYDevice: $0) } ?? []
        let explicitScopeProcessIDs = surfaceID.map { pids(forCMUXSurfaceID: $0) } ?? []

        var rootProcessIDs = explicitScopeProcessIDs
        var ownedProcessIDs = expandedOwnedPIDs(
            rootProcessIDs: explicitScopeProcessIDs,
            surfaceID: surfaceID
        )
        var reasonByProcessID: [Int: String] = [:]

        for processID in ownedProcessIDs {
            guard let process = process(pid: processID) else { continue }
            if let surfaceID,
               process.cmuxSurfaceID == surfaceID,
               let explicitReason = process.cmuxAttributionReason {
                reasonByProcessID[processID] = explicitReason
            } else if let surfaceID, process.cmuxSurfaceID == surfaceID {
                reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.explicitScope.rawValue
            } else {
                reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.descendant.rawValue
            }
        }

        // A live process tree is strong evidence for ordinary terminal shells,
        // even when scope arguments were unavailable to the snapshot reader.
        let applicationDescendantTTYProcessIDs = observedTTYProcessIDs.filter { processID in
            processID != applicationPID &&
                isSnapshotDescendant(processID, of: applicationPID) &&
                !hasConflictingScope(processID, surfaceID: surfaceID)
        }
        if !applicationDescendantTTYProcessIDs.isEmpty {
            rootProcessIDs.formUnion(topLevelRoots(
                applicationDescendantTTYProcessIDs,
                alreadyOwned: ownedProcessIDs
            ))
            let descendantPIDs = expandedOwnedPIDs(
                rootProcessIDs: applicationDescendantTTYProcessIDs,
                surfaceID: surfaceID
            )
            for processID in descendantPIDs {
                ownedProcessIDs.insert(processID)
                if reasonByProcessID[processID] == nil {
                    reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.descendant.rawValue
                }
            }
        }

        // A launchd helper without scope is accepted only when its executable
        // identifies it as cmux and its process group joins proven lineage.
        // TPGID describes the terminal's foreground group, so it is not an
        // ownership proof by itself; TTY alone does not prove ownership either.
        let provenGroupIDs: Set<Int> = Set(ownedProcessIDs.compactMap { processID in
            guard let process = process(pid: processID) else { return nil }
            guard let processGroupID = process.processGroupID, processGroupID > 1 else {
                return nil
            }
            return processGroupID
        })
        let processGroupHelpers = observedTTYProcessIDs.filter { processID in
            guard !ownedProcessIDs.contains(processID),
                  !hasConflictingScope(processID, surfaceID: surfaceID),
                  let process = process(pid: processID),
                  isIdentifiableCMUXHelper(process) else {
                return false
            }
            guard let processGroupID = process.processGroupID, processGroupID > 1 else {
                return false
            }
            return provenGroupIDs.contains(processGroupID)
        }
        if !processGroupHelpers.isEmpty {
            rootProcessIDs.formUnion(processGroupHelpers)
            let helperPIDs = expandedOwnedPIDs(
                rootProcessIDs: processGroupHelpers,
                surfaceID: surfaceID
            )
            for processID in helperPIDs {
                ownedProcessIDs.insert(processID)
                if reasonByProcessID[processID] == nil {
                    reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.processGroup.rawValue
                }
            }
        }

        var ambiguousTTYProcessIDs = observedTTYProcessIDs.subtracting(ownedProcessIDs)
        for processID in ambiguousTTYProcessIDs {
            if hasConflictingScope(processID, surfaceID: surfaceID) {
                reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.conflictingScope.rawValue
            } else {
                reasonByProcessID[processID] = CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue
            }
        }

        // A process with explicit scope for this surface is authoritative even
        // when it has no TTY; only the TTY intersection is exposed as ownedTTY.
        let ownedTTYProcessIDs = ownedProcessIDs.intersection(observedTTYProcessIDs)
        ambiguousTTYProcessIDs.subtract(ownedTTYProcessIDs)

        return CmuxTopTerminalProcessOwnership(
            explicitScopeProcessIDs: explicitScopeProcessIDs,
            observedTTYProcessIDs: observedTTYProcessIDs,
            ownedTTYProcessIDs: ownedTTYProcessIDs,
            ambiguousTTYProcessIDs: ambiguousTTYProcessIDs,
            ownedProcessIDs: ownedProcessIDs,
            rootProcessIDs: rootProcessIDs,
            reasonByProcessID: reasonByProcessID
        )
    }

    private func isSnapshotDescendant(_ processID: Int, of rootProcessID: Int) -> Bool {
        guard processID > 0, rootProcessID > 0, processID != rootProcessID else {
            return false
        }

        var currentProcessID = processID
        var visited: Set<Int> = []
        while visited.insert(currentProcessID).inserted,
              let parentProcessID = process(pid: currentProcessID)?.parentPID,
              parentProcessID > 0 {
            if parentProcessID == rootProcessID {
                return true
            }
            currentProcessID = parentProcessID
        }
        return false
    }

    private func topLevelRoots(_ processIDs: Set<Int>, alreadyOwned: Set<Int>) -> Set<Int> {
        processIDs.filter { processID in
            guard let parentProcessID = process(pid: processID)?.parentPID else { return true }
            return !processIDs.contains(parentProcessID) && !alreadyOwned.contains(parentProcessID)
        }
    }

    private func hasConflictingScope(_ processID: Int, surfaceID: UUID?) -> Bool {
        guard let processSurfaceID = process(pid: processID)?.cmuxSurfaceID else {
            return false
        }
        return processSurfaceID != surfaceID
    }

    private func expandedOwnedPIDs(
        rootProcessIDs: Set<Int>,
        surfaceID: UUID?
    ) -> Set<Int> {
        let expanded = expandedPIDs(rootPIDs: rootProcessIDs)
        return Set(expanded.filter { processID in
            guard !hasConflictingScope(processID, surfaceID: surfaceID) else {
                return false
            }
            if rootProcessIDs.contains(processID) {
                return true
            }
            var currentProcessID = processID
            var visited: Set<Int> = []
            while visited.insert(currentProcessID).inserted,
                  let parentProcessID = process(pid: currentProcessID)?.parentPID,
                  parentProcessID > 0 {
                if rootProcessIDs.contains(parentProcessID) {
                    break
                }
                if hasConflictingScope(parentProcessID, surfaceID: surfaceID) {
                    return false
                }
                currentProcessID = parentProcessID
            }
            return true
        })
    }

    private func isIdentifiableCMUXHelper(_ process: CmuxTopProcessInfo) -> Bool {
        let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathName = process.path
            .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        let identifiableNames = Set(["cmux", "cmuxd", "cmux-helper", "cmux-agent"])
        return identifiableNames.contains(name) ||
            (pathName.map { identifiableNames.contains($0) } ?? false)
    }
}
