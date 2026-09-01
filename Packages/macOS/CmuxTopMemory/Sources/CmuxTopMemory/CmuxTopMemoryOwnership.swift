public import Foundation

/// Evidence used when a terminal TTY is observed in a top snapshot.
public enum CmuxTopMemoryOwnershipReason: String, Sendable {
    /// The process supplied an explicit cmux surface scope.
    case explicitScope = "cmux-explicit-scope"
    /// The process was reached through a proven cmux process tree.
    case descendant = "cmux-descendant"
    /// The process matched a trusted helper in a proven process group.
    case processGroup = "cmux-process-group"
    /// The process shares a TTY but has no ownership proof.
    case sameTTYUnproven = "same-tty-unproven"
    /// The process is explicitly scoped to another surface.
    case conflictingScope = "conflicting-cmux-scope"
    /// The process is the root of an explicitly attributed WebKit tree.
    case webViewRoot = "webview-root-pid"
}

/// Separates TTY observations from process IDs whose cmux ownership is proven.
public struct CmuxTopMemoryTerminalOwnership: Equatable, Sendable {
    /// Processes carrying an explicit surface scope for the queried surface.
    public let explicitScopeProcessIDs: Set<Int>
    /// All sampled processes observed on the queried TTY.
    public let observedTTYProcessIDs: Set<Int>
    /// TTY processes accepted as owned by the queried surface.
    public let ownedTTYProcessIDs: Set<Int>
    /// TTY processes retained because ownership could not be proven.
    public let ambiguousTTYProcessIDs: Set<Int>
    /// Every process included by explicit scope, lineage, or helper evidence.
    public let ownedProcessIDs: Set<Int>
    /// Roots used to derive the owned process set.
    public let rootProcessIDs: Set<Int>
    /// Raw ownership evidence keyed by process ID.
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

/// Resolves terminal ownership from one immutable process-record snapshot.
public struct CmuxTopProcessOwnershipResolver: Sendable {
    private let processesByPID: [Int: CmuxTopMemoryProcessRecord]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]
    private let pidsBySurfaceID: [UUID: [Int]]
    private let canonicalExecutablePathByPID: [Int: String]
    private let trustedExecutablePaths: Set<String>
    private let applicationPID: Int
    private let applicationDescendantPIDs: Set<Int>

    /// Creates indexes and immutable ownership evidence caches for a snapshot.
    ///
    /// Canonical paths and application descendants are computed here once. The
    /// resolver can then answer any number of surface queries without filesystem
    /// work or a second process-tree expansion.
    ///
    /// - Parameters:
    ///   - processes: The process facts captured at one sampling point.
    ///   - applicationPID: The cmux application PID whose descendants may be
    ///     attributed by lineage. Pass `0` when no application root is known.
    ///   - trustedExecutablePaths: Full executable paths registered by the app
    ///     or its launcher and eligible for process-group helper attribution.
    public init(
        processes: [CmuxTopMemoryProcessRecord],
        applicationPID: Int = 0,
        trustedExecutablePaths: Set<String> = []
    ) {
        var processMap: [Int: CmuxTopMemoryProcessRecord] = [:]
        processMap.reserveCapacity(processes.count)
        for process in processes {
            processMap[process.pid] = process
        }
        self.processesByPID = processMap
        self.applicationPID = applicationPID

        var children: [Int: [Int]] = [:]
        var ttyPIDs: [Int64: [Int]] = [:]
        var surfacePIDs: [UUID: [Int]] = [:]
        var canonicalPaths: [Int: String] = [:]
        canonicalPaths.reserveCapacity(processMap.count)
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
            if let canonicalPath = Self.canonicalExecutablePath(process.path) {
                canonicalPaths[process.pid] = canonicalPath
            }
        }
        let sortedChildren = children.mapValues { $0.sorted() }
        self.childrenByParentPID = sortedChildren
        self.pidsByTTYDevice = ttyPIDs.mapValues { $0.sorted() }
        self.pidsBySurfaceID = surfacePIDs.mapValues { $0.sorted() }
        self.canonicalExecutablePathByPID = canonicalPaths
        self.trustedExecutablePaths = Set(trustedExecutablePaths.compactMap(Self.canonicalExecutablePath))
        self.applicationDescendantPIDs = applicationPID > 0
            ? Self.expandedPIDs(rootPID: applicationPID, childrenByParentPID: sortedChildren)
                .subtracting([applicationPID])
            : []
    }

    /// Resolves one surface's TTY, retaining unmatched processes as ambiguous.
    ///
    /// A controlling TTY is only an observation. Processes reparented to PID 1
    /// can retain it after leaving cmux's tree, so TTY membership never proves
    /// ownership on its own. Helper paths must be canonical full paths supplied
    /// by a trusted launcher or app-bundle adapter.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface being queried, if known.
    ///   - ttyDevice: The controlling TTY device number, if known.
    /// - Returns: Ownership facts and per-process evidence for this surface.
    public func resolve(
        surfaceID: UUID?,
        ttyDevice: Int64?
    ) -> CmuxTopMemoryTerminalOwnership {
        let observedTTYProcessIDs = Set(ttyDevice.flatMap { pidsByTTYDevice[$0] } ?? [])
        let explicitScopeProcessIDs = Set(surfaceID.flatMap { pidsBySurfaceID[$0] } ?? [])

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
                  isTrustedHelper(processID: process.pid),
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

        let ambiguousTTYProcessIDs = observedTTYProcessIDs.subtracting(ownedProcessIDs)
        for processID in ambiguousTTYProcessIDs {
            reasonByProcessID[processID] = hasConflictingScope(processID, surfaceID: surfaceID)
                ? CmuxTopMemoryOwnershipReason.conflictingScope.rawValue
                : CmuxTopMemoryOwnershipReason.sameTTYUnproven.rawValue
        }
        let ownedTTYProcessIDs = ownedProcessIDs.intersection(observedTTYProcessIDs)

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
    private static func expandedPIDs(
        rootPID: Int,
        childrenByParentPID: [Int: [Int]]
    ) -> Set<Int> {
        var result: Set<Int> = []
        var worklist = rootPID > 0 ? [rootPID] : []
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

    /// Matches a helper by its cached canonical executable identity.
    private func isTrustedHelper(processID: Int) -> Bool {
        guard let canonicalPath = canonicalExecutablePathByPID[processID] else { return false }
        return trustedExecutablePaths.contains(canonicalPath)
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
