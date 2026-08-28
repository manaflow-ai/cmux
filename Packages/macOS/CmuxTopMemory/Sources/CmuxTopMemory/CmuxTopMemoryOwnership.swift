public import Foundation

/// Evidence used when a terminal TTY is observed in a top snapshot.
public enum CmuxTopMemoryOwnershipReason: String, Sendable {
    case explicitScope = "cmux-explicit-scope"
    case descendant = "cmux-descendant"
    case processGroup = "cmux-process-group"
    case sameTTYUnproven = "same-tty-unproven"
    case conflictingScope = "conflicting-cmux-scope"
    case webViewRoot = "webview-root-pid"
}

/// Separates TTY observations from process IDs whose cmux ownership is proven.
public struct CmuxTopMemoryTerminalOwnership: Equatable, Sendable {
    public let explicitScopeProcessIDs: Set<Int>
    public let observedTTYProcessIDs: Set<Int>
    public let ownedTTYProcessIDs: Set<Int>
    public let ambiguousTTYProcessIDs: Set<Int>
    public let ownedProcessIDs: Set<Int>
    public let rootProcessIDs: Set<Int>
    public let reasonByProcessID: [Int: String]

    /// Indicates that at least one TTY process has no accepted ownership proof.
    public var hasAmbiguousTTYProcesses: Bool {
        !ambiguousTTYProcessIDs.isEmpty
    }

    /// Serializes ownership evidence for the top payload contract.
    public func payload() -> [String: Any] {
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

/// Resolves terminal ownership from a point-in-time process record set.
public struct CmuxTopProcessOwnershipResolver: Sendable {
    private let processesByPID: [Int: CmuxTopMemoryProcessRecord]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]
    private let pidsBySurfaceID: [UUID: [Int]]

    /// Creates a resolver with indexes that are reused for each surface query.
    public init(processes: [CmuxTopMemoryProcessRecord]) {
        var processMap: [Int: CmuxTopMemoryProcessRecord] = [:]
        processMap.reserveCapacity(processes.count)
        for process in processes {
            processMap[process.pid] = process
        }
        self.processesByPID = processMap

        var children: [Int: [Int]] = [:]
        var ttyPIDs: [Int64: [Int]] = [:]
        var surfacePIDs: [UUID: [Int]] = [:]
        for process in processMap.values {
            if process.parentPID > 0 {
                children[process.parentPID, default: []].append(process.pid)
            }
            if let ttyDevice = process.ttyDevice {
                ttyPIDs[ttyDevice, default: []].append(process.pid)
            }
            if let surfaceID = process.surfaceID {
                surfacePIDs[surfaceID, default: []].append(process.pid)
            }
        }
        self.childrenByParentPID = children.mapValues { $0.sorted() }
        self.pidsByTTYDevice = ttyPIDs.mapValues { $0.sorted() }
        self.pidsBySurfaceID = surfacePIDs.mapValues { $0.sorted() }
    }

    /// Resolves one surface's TTY, retaining unmatched processes as ambiguous.
    ///
    /// A controlling TTY is only an observation. Processes reparented to PID 1
    /// can retain it after leaving cmux's tree, so TTY membership never proves
    /// ownership on its own. Helper paths must be canonical full paths supplied
    /// by a trusted launcher or app-bundle adapter.
    public func resolve(
        surfaceID: UUID?,
        ttyDevice: Int64?,
        applicationPID: Int,
        trustedExecutablePaths: Set<String> = []
    ) -> CmuxTopMemoryTerminalOwnership {
        let observedTTYProcessIDs = Set(ttyDevice.flatMap { pidsByTTYDevice[$0] } ?? [])
        let explicitScopeProcessIDs = Set(surfaceID.flatMap { pidsBySurfaceID[$0] } ?? [])
        let trustedPaths = Set(trustedExecutablePaths.compactMap(Self.canonicalExecutablePath))

        var rootProcessIDs = explicitScopeProcessIDs
        var ownedProcessIDs = expandedOwnedPIDs(
            rootProcessIDs: explicitScopeProcessIDs,
            surfaceID: surfaceID
        )
        var reasonByProcessID: [Int: String] = [:]
        for processID in ownedProcessIDs {
            guard let process = processesByPID[processID] else { continue }
            if let surfaceID,
               process.surfaceID == surfaceID,
               let explicitReason = process.attributionReason {
                reasonByProcessID[processID] = explicitReason
            } else if let surfaceID, process.surfaceID == surfaceID {
                reasonByProcessID[processID] = CmuxTopMemoryOwnershipReason.explicitScope.rawValue
            } else {
                reasonByProcessID[processID] = CmuxTopMemoryOwnershipReason.descendant.rawValue
            }
        }

        let applicationDescendantPIDs = applicationPID > 0
            ? expandedPIDs(rootPIDs: [applicationPID]).subtracting([applicationPID])
            : []
        let applicationDescendantTTYProcessIDs = observedTTYProcessIDs
            .intersection(applicationDescendantPIDs)
            .filter { !hasConflictingScope($0, surfaceID: surfaceID) }
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
                    reasonByProcessID[processID] = CmuxTopMemoryOwnershipReason.descendant.rawValue
                }
            }
        }

        let provenGroupIDs: Set<Int> = Set(ownedProcessIDs.compactMap { processID in
            guard let groupID = processesByPID[processID]?.processGroupID, groupID > 1 else {
                return nil
            }
            return groupID
        })
        let processGroupHelpers = observedTTYProcessIDs.filter { processID in
            guard !ownedProcessIDs.contains(processID),
                  processID != applicationPID,
                  !hasConflictingScope(processID, surfaceID: surfaceID),
                  let process = processesByPID[processID],
                  isTrustedHelper(process, trustedExecutablePaths: trustedPaths),
                  let groupID = process.processGroupID,
                  groupID > 1 else {
                return false
            }
            return provenGroupIDs.contains(groupID)
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
                    reasonByProcessID[processID] = CmuxTopMemoryOwnershipReason.processGroup.rawValue
                }
            }
        }

        var ambiguousTTYProcessIDs = observedTTYProcessIDs.subtracting(ownedProcessIDs)
        for processID in ambiguousTTYProcessIDs {
            reasonByProcessID[processID] = hasConflictingScope(processID, surfaceID: surfaceID)
                ? CmuxTopMemoryOwnershipReason.conflictingScope.rawValue
                : CmuxTopMemoryOwnershipReason.sameTTYUnproven.rawValue
        }
        let ownedTTYProcessIDs = ownedProcessIDs.intersection(observedTTYProcessIDs)
        ambiguousTTYProcessIDs.subtract(ownedTTYProcessIDs)

        return CmuxTopMemoryTerminalOwnership(
            explicitScopeProcessIDs: explicitScopeProcessIDs,
            observedTTYProcessIDs: observedTTYProcessIDs,
            ownedTTYProcessIDs: ownedTTYProcessIDs,
            ambiguousTTYProcessIDs: ambiguousTTYProcessIDs,
            ownedProcessIDs: ownedProcessIDs,
            rootProcessIDs: rootProcessIDs,
            reasonByProcessID: reasonByProcessID
        )
    }

    /// Expands roots once, stopping at a conflicting scope boundary.
    private func expandedOwnedPIDs(
        rootProcessIDs: Set<Int>,
        surfaceID: UUID?
    ) -> Set<Int> {
        var ownedProcessIDs: Set<Int> = []
        var visitedProcessIDs: Set<Int> = []
        var worklist = Array(rootProcessIDs.filter { $0 > 0 })
        while let processID = worklist.popLast() {
            guard visitedProcessIDs.insert(processID).inserted,
                  let process = processesByPID[processID],
                  !hasConflictingScope(processID, surfaceID: surfaceID) else {
                continue
            }
            ownedProcessIDs.insert(processID)
            worklist.append(contentsOf: childrenByParentPID[process.pid] ?? [])
        }
        return ownedProcessIDs
    }

    /// Expands a process tree with a cycle-safe worklist.
    private func expandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var worklist = Array(rootPIDs.filter { $0 > 0 })
        while let processID = worklist.popLast() {
            guard result.insert(processID).inserted else { continue }
            worklist.append(contentsOf: childrenByParentPID[processID] ?? [])
        }
        return result
    }

    /// Keeps only observed roots that are not already covered by another root.
    private func topLevelRoots(_ processIDs: Set<Int>, alreadyOwned: Set<Int>) -> Set<Int> {
        processIDs.filter { processID in
            guard let parentPID = processesByPID[processID]?.parentPID else { return true }
            return !processIDs.contains(parentPID) && !alreadyOwned.contains(parentPID)
        }
    }

    /// Identifies a process explicitly scoped to a different surface.
    private func hasConflictingScope(_ processID: Int, surfaceID: UUID?) -> Bool {
        guard let processSurfaceID = processesByPID[processID]?.surfaceID else { return false }
        return processSurfaceID != surfaceID
    }

    /// Matches helpers by canonical full executable identity only.
    private func isTrustedHelper(
        _ process: CmuxTopMemoryProcessRecord,
        trustedExecutablePaths: Set<String>
    ) -> Bool {
        guard let path = Self.canonicalExecutablePath(process.path) else { return false }
        return trustedExecutablePaths.contains(path)
    }

    /// Normalizes an executable path before trusted-identity comparison.
    private static func canonicalExecutablePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        let canonicalPath = URL(fileURLWithPath: trimmedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return canonicalPath.hasPrefix("/") ? canonicalPath : nil
    }
}
