import Foundation
import Darwin
import os

private nonisolated let cmuxTopPIDPathBufferSize = 4096
private nonisolated let cmuxTopMemoryDiagnosticDefaultGroupLimit = 12

nonisolated struct CmuxTopProcessAttribution: Hashable, Sendable {
    let workspaceID: UUID?
    let workspaceRef: String?
    let paneID: UUID?
    let paneRef: String?
    let surfaceID: UUID?
    let surfaceRef: String?
    let reason: String

    func payload() -> [String: Any] {
        [
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "workspace_ref": workspaceRef as Any? ?? NSNull(),
            "pane_id": paneID?.uuidString as Any? ?? NSNull(),
            "pane_ref": paneRef as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "surface_ref": surfaceRef as Any? ?? NSNull(),
            "reason": reason
        ]
    }
}

private nonisolated struct CmuxTopProcessSnapshotCacheState {
    var snapshot: CmuxTopProcessSnapshot?
    var includeProcessDetails = false
}

private nonisolated let cmuxTopProcessSnapshotCache = OSAllocatedUnfairLock(
    initialState: CmuxTopProcessSnapshotCacheState()
)

nonisolated struct CmuxTopResourceSummary: Sendable {
    var cpuPercent: Double = 0
    var memoryBytes: Int64 = 0
    var residentBytes: Int64 = 0
    var virtualBytes: Int64 = 0
    var processCount: Int = 0
    var pids: [Int] = []
    var missingPIDs: [Int] = []
    var memorySourceFallbackPIDs: [Int] = []
    var residentMemorySourceFallbackPIDs: [Int] = []
    var unavailableMemoryPIDs: [Int] = []
    var unavailableResidentMemoryPIDs: [Int] = []

    func payload() -> [String: Any] {
        [
            "cpu_percent": cpuPercent,
            "memory_bytes": memoryBytes,
            "resident_bytes": residentBytes,
            "virtual_bytes": virtualBytes,
            "process_count": processCount,
            "pids": pids,
            "missing_pids": missingPIDs,
            "memory_source_fallback_pids": memorySourceFallbackPIDs,
            "memory_source_fallback_count": memorySourceFallbackPIDs.count,
            "resident_memory_source_fallback_pids": residentMemorySourceFallbackPIDs,
            "resident_memory_source_fallback_count": residentMemorySourceFallbackPIDs.count,
            "unavailable_memory_pids": unavailableMemoryPIDs,
            "unavailable_memory_count": unavailableMemoryPIDs.count,
            "unavailable_resident_memory_pids": unavailableResidentMemoryPIDs,
            "unavailable_resident_memory_count": unavailableResidentMemoryPIDs.count
        ]
    }

    func attributedPayload(sharedAcross occurrenceCount: Int) -> [String: Any] {
        guard occurrenceCount > 1 else { return payload() }
        var attributed = self
        attributed.cpuPercent /= Double(occurrenceCount)
        attributed.memoryBytes = attributed.memoryBytes / Int64(occurrenceCount)
        attributed.residentBytes = attributed.residentBytes / Int64(occurrenceCount)
        attributed.virtualBytes = attributed.virtualBytes / Int64(occurrenceCount)
        return attributed.payload()
    }
}

nonisolated enum CmuxTopProcessMemorySource: String, Sendable {
    case physicalFootprint = "proc_pid_rusage.RUSAGE_INFO_V4.ri_phys_footprint"
    case residentSize = "proc_pidinfo.PROC_PIDTASKINFO.pti_resident_size"
    case rusageResidentSize = "proc_pid_rusage.RUSAGE_INFO_V4.ri_resident_size"
    case mixed
    case unavailable
}

nonisolated struct CmuxTopProcessInfo: Sendable {
    let pid: Int
    let parentPID: Int
    let name: String
    let path: String?
    let ttyDevice: Int64?
    let cmuxWorkspaceID: UUID?
    let cmuxSurfaceID: UUID?
    let cmuxAttributionReason: String?
    let processGroupID: Int?
    let terminalProcessGroupID: Int?
    var cpuPercent: Double
    let memoryBytes: Int64
    let memorySource: CmuxTopProcessMemorySource
    let residentBytes: Int64
    let residentMemorySource: CmuxTopProcessMemorySource
    let virtualBytes: Int64
    let threadCount: Int

    init(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String?,
        ttyDevice: Int64?,
        cmuxWorkspaceID: UUID?,
        cmuxSurfaceID: UUID?,
        cmuxAttributionReason: String?,
        processGroupID: Int?,
        terminalProcessGroupID: Int?,
        cpuPercent: Double,
        memoryBytes: Int64? = nil,
        memorySource: CmuxTopProcessMemorySource? = nil,
        residentBytes: Int64,
        residentMemorySource: CmuxTopProcessMemorySource = .residentSize,
        virtualBytes: Int64,
        threadCount: Int
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.path = path
        self.ttyDevice = ttyDevice
        self.cmuxWorkspaceID = cmuxWorkspaceID
        self.cmuxSurfaceID = cmuxSurfaceID
        self.cmuxAttributionReason = cmuxAttributionReason
        self.processGroupID = processGroupID
        self.terminalProcessGroupID = terminalProcessGroupID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes ?? residentBytes
        self.memorySource = memorySource
            ?? (memoryBytes == nil ? .residentSize : .physicalFootprint)
        self.residentBytes = residentBytes
        self.residentMemorySource = residentMemorySource
        self.virtualBytes = virtualBytes
        self.threadCount = threadCount
    }

    var isTerminalForegroundProcessGroup: Bool {
        guard let processGroupID, let terminalProcessGroupID else { return false }
        return processGroupID == terminalProcessGroupID
    }
}

nonisolated struct CmuxTopProcessScope: Sendable {
    let workspaceID: UUID?
    let surfaceID: UUID?
    let attributionReason: String

    init(workspaceID: UUID?, surfaceID: UUID?, attributionReason: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.attributionReason = attributionReason
    }
}

nonisolated final class CmuxTopProcessSnapshot: @unchecked Sendable {
    let sampledAt: Date
    private let includesProcessDetails: Bool
    private let processesByPID: [Int: CmuxTopProcessInfo]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]
    private let pidsByCMUXSurfaceID: [UUID: [Int]]
    private let residentMemorySources: [CmuxTopProcessMemorySource]

    static func capture(includeProcessDetails: Bool = false) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: allProcesses(includeProcessDetails: includeProcessDetails),
            sampledAt: Date(),
            includesProcessDetails: includeProcessDetails
        )
    }

    static func captureCached(
        includeProcessDetails: Bool = false,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        let now = Date()
        if let cached = cmuxTopProcessSnapshotCache.withLock({ state -> CmuxTopProcessSnapshot? in
            guard state.includeProcessDetails == includeProcessDetails,
                  let snapshot = state.snapshot,
                  now.timeIntervalSince(snapshot.sampledAt) <= maximumAge else {
                return nil
            }
            return snapshot
        }) {
            return cached
        }

        let snapshot = capture(includeProcessDetails: includeProcessDetails)
        cmuxTopProcessSnapshotCache.withLock { state in
            state.snapshot = snapshot
            state.includeProcessDetails = includeProcessDetails
        }
        return snapshot
    }

    init(
        processes: [CmuxTopProcessInfo],
        sampledAt: Date,
        includesProcessDetails: Bool
    ) {
        self.sampledAt = sampledAt
        self.includesProcessDetails = includesProcessDetails
        var processMap: [Int: CmuxTopProcessInfo] = [:]
        processMap.reserveCapacity(processes.count)
        for process in processes {
            processMap[process.pid] = process
        }
        self.processesByPID = processMap
        self.residentMemorySources = Self.sortedMemorySources(
            in: processMap.values.map(\.residentMemorySource)
        )

        var children: [Int: [Int]] = [:]
        var ttyMap: [Int64: [Int]] = [:]
        var cmuxSurfaceMap: [UUID: [Int]] = [:]
        for process in processMap.values {
            if process.parentPID > 0 {
                children[process.parentPID, default: []].append(process.pid)
            }
            if let ttyDevice = process.ttyDevice {
                ttyMap[ttyDevice, default: []].append(process.pid)
            }
            if let cmuxSurfaceID = process.cmuxSurfaceID {
                cmuxSurfaceMap[cmuxSurfaceID, default: []].append(process.pid)
            }
        }
        self.childrenByParentPID = children.mapValues { $0.sorted() }
        self.pidsByTTYDevice = ttyMap.mapValues { $0.sorted() }
        self.pidsByCMUXSurfaceID = cmuxSurfaceMap.mapValues { $0.sorted() }
    }

    func samplePayload() -> [String: Any] {
        let residentMemorySourceNames = residentMemorySources.map(\.rawValue)
        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "source": "proc_listallpids+proc_pidinfo",
            "cpu_source": "proc_pidinfo.PROC_PIDTASKINFO.pti_total_user+pti_total_system",
            "memory_source": CmuxTopProcessMemorySource.physicalFootprint.rawValue,
            "memory_fallback_source": CmuxTopProcessMemorySource.residentSize.rawValue,
            "resident_memory_source": Self.summaryMemorySource(residentMemorySources).rawValue,
            "resident_memory_sources": residentMemorySourceNames,
            "resident_memory_fallback_source": CmuxTopProcessMemorySource.rusageResidentSize.rawValue,
            "process_details": includesProcessDetails
        ]
    }

    private static func sortedMemorySources(
        in sources: [CmuxTopProcessMemorySource]
    ) -> [CmuxTopProcessMemorySource] {
        [
            .physicalFootprint,
            .residentSize,
            .rusageResidentSize,
            .unavailable
        ].filter { source in
            sources.contains(source)
        }
    }

    private static func summaryMemorySource(
        _ sources: [CmuxTopProcessMemorySource]
    ) -> CmuxTopProcessMemorySource {
        let concreteSources = sources.filter { $0 != .unavailable }
        guard !concreteSources.isEmpty else { return .unavailable }
        guard concreteSources.count == 1, let source = concreteSources.first else {
            return .mixed
        }
        return source
    }

    func pids(forTTYName ttyName: String) -> Set<Int> {
        guard let device = Self.deviceIdentifier(forTTYName: ttyName) else {
            return []
        }
        return Set(pidsByTTYDevice[device] ?? [])
    }

    func pids(forCMUXSurfaceID surfaceID: UUID) -> Set<Int> {
        Set(pidsByCMUXSurfaceID[surfaceID] ?? [])
    }

    func cmuxScopedProcesses() -> [CmuxTopProcessInfo] {
        processesByPID.values
            .filter { $0.cmuxWorkspaceID != nil && $0.cmuxSurfaceID != nil }
            .sorted { $0.pid < $1.pid }
    }

    func process(pid: Int) -> CmuxTopProcessInfo? {
        processesByPID[pid]
    }

    func expandedPIDs(rootPIDs: Set<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var stack = Array(rootPIDs.filter { $0 > 0 })

        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
        }

        return result
    }

    func descendantPIDs(rootPID: Int, includeRoot: Bool = false) -> Set<Int> {
        guard rootPID > 0 else { return [] }

        var result: Set<Int> = includeRoot && processesByPID[rootPID] != nil ? [rootPID] : []
        var stack = childrenByParentPID[rootPID] ?? []
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
        }
        return result
    }

    func memoryDiagnosticPayload(
        appPID: Int = Int(Darwin.getpid()),
        topGroupLimit: Int = cmuxTopMemoryDiagnosticDefaultGroupLimit,
        attributionByPID: [Int: CmuxTopProcessAttribution] = [:]
    ) -> [String: Any] {
        let appResources = summaryPayload(for: [appPID], rootPIDs: [appPID])
        let appProcess = processesByPID[appPID]
        let childPIDs = descendantPIDs(rootPID: appPID, includeRoot: false)
            .filter { processesByPID[$0] != nil }
        let childSummary = summary(for: childPIDs)
        let groups = memoryDiagnosticGroups(
            for: childPIDs,
            topGroupLimit: topGroupLimit,
            attributionByPID: attributionByPID
        )
        let topGroup = groups.first

        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "app": [
                "pid": appPID,
                "name": appProcess?.name ?? "cmux",
                "path": appProcess?.path as Any? ?? NSNull(),
                "resources": appResources,
                "physical_footprint_bytes": appProcess?.memoryBytes ?? 0,
                "resident_bytes": appProcess?.residentBytes ?? 0,
                "memory_source": appProcess?.memorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue,
                "resident_memory_source": appProcess?.residentMemorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
            ] as [String: Any],
            "children": [
                "root_pid": appPID,
                "recursive_rss_bytes": childSummary.residentBytes,
                "process_count": childSummary.processCount,
                "pids": childSummary.pids,
                "groups": groups
            ] as [String: Any],
            "summary": memoryDiagnosticSummaryText(
                appFootprintBytes: appProcess?.memoryBytes ?? 0,
                childRSSBytes: childSummary.residentBytes,
                topGroup: topGroup
            )
        ]
    }

    func summaryPayload(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> [String: Any] {
        summary(for: pids, rootPIDs: rootPIDs).payload()
    }

    func summary(for pids: Set<Int>, rootPIDs: Set<Int> = []) -> CmuxTopResourceSummary {
        let sortedPIDs = pids.filter { $0 > 0 }.sorted()
        var summary = CmuxTopResourceSummary()
        summary.pids = sortedPIDs
        summary.missingPIDs = rootPIDs
            .filter { $0 > 0 && processesByPID[$0] == nil }
            .sorted()

        for pid in sortedPIDs {
            guard let process = processesByPID[pid] else { continue }
            summary.cpuPercent += process.cpuPercent
            summary.memoryBytes = Self.clampedAdd(summary.memoryBytes, process.memoryBytes)
            summary.residentBytes = Self.clampedAdd(summary.residentBytes, process.residentBytes)
            summary.virtualBytes = Self.clampedAdd(summary.virtualBytes, process.virtualBytes)
            summary.processCount += 1
            if process.memorySource == .residentSize {
                summary.memorySourceFallbackPIDs.append(pid)
            } else if process.memorySource == .unavailable {
                summary.unavailableMemoryPIDs.append(pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                summary.residentMemorySourceFallbackPIDs.append(pid)
            } else if process.residentMemorySource == .unavailable {
                summary.unavailableResidentMemoryPIDs.append(pid)
            }
        }

        return summary
    }

    func programSummaryPayload(for pids: Set<Int>) -> [[String: Any]] {
        var aggregates: [String: CmuxProgramProcessAggregate] = [:]

        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let title = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title.lowercased()
            if aggregates[key] == nil {
                aggregates[key] = CmuxProgramProcessAggregate(id: key, title: title)
            }
            aggregates[key]?.append(process)
        }

        return aggregates.values
            .filter { $0.processIds.count > 1 }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { $0.payload() }
    }

    func processTreePayload(for pids: Set<Int>, rootPIDs explicitRootPIDs: Set<Int> = []) -> [[String: Any]] {
        let allowedPIDs = Set(pids.filter { processesByPID[$0] != nil })
        guard !allowedPIDs.isEmpty else { return [] }

        let roots: [Int]
        if explicitRootPIDs.isEmpty {
            roots = allowedPIDs
                .filter { pid in
                    guard let parent = processesByPID[pid]?.parentPID else { return true }
                    return !allowedPIDs.contains(parent)
                }
                .sorted { processSortKey($0) < processSortKey($1) }
        } else {
            let explicit = explicitRootPIDs.filter { allowedPIDs.contains($0) }
            let orphaned = allowedPIDs.filter { pid in
                explicit.contains(pid) || !allowedPIDs.contains(processesByPID[pid]?.parentPID ?? 0)
            }
            roots = Array(orphaned).sorted { processSortKey($0) < processSortKey($1) }
        }

        var visited: Set<Int> = []
        return roots.compactMap {
            processTreeNode(
                pid: $0,
                allowedPIDs: allowedPIDs,
                rootPIDs: explicitRootPIDs,
                visited: &visited
            )
        }
    }

    func topLevelPIDs(for pids: Set<Int>) -> Set<Int> {
        let allowedPIDs = Set(pids.filter { processesByPID[$0] != nil })
        return allowedPIDs.filter { pid in
            guard let parent = processesByPID[pid]?.parentPID else { return true }
            return !allowedPIDs.contains(parent)
        }
    }

    func foregroundProcessGroupIDs(for pids: Set<Int>) -> Set<Int> {
        Set(
            pids.compactMap { pid in
                guard let process = processesByPID[pid],
                      process.isTerminalForegroundProcessGroup else {
                    return nil
                }
                return process.terminalProcessGroupID
            }
        )
    }

    func codingAgentSummaryPayload(for pids: Set<Int>) -> [[String: Any]] {
        var aggregates: [String: CmuxCodingAgentProcessAggregate] = [:]

        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let processArguments = Self.processArgumentsIfNeeded(for: process)
            guard let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: process.name,
                processPath: process.path,
                arguments: processArguments?.arguments ?? [],
                environment: processArguments?.environment ?? [:]
            ) else { continue }

            if aggregates[definition.id] == nil {
                aggregates[definition.id] = CmuxCodingAgentProcessAggregate(definition: definition)
            }
            aggregates[definition.id]?.append(process)
        }

        return CmuxTaskManagerCodingAgentDefinition.builtIns.compactMap { definition in
            guard let aggregate = aggregates[definition.id] else { return nil }
            return aggregate.payload()
        }
    }

    private static func processArgumentsIfNeeded(for process: CmuxTopProcessInfo) -> CmuxTopProcessArguments? {
        guard CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        ) else { return nil }
        return processArgumentsAndEnvironment(for: process.pid)
    }

    private struct CmuxProgramProcessAggregate {
        let id: String
        let title: String
        var cpuPercent: Double = 0
        var memoryBytes: Int64 = 0
        var residentBytes: Int64 = 0
        var processIds: [Int] = []
        var seenProcessIds: Set<Int> = []
        var memorySourceFallbackPIDs: [Int] = []
        var residentMemorySourceFallbackPIDs: [Int] = []
        var unavailableMemoryPIDs: [Int] = []
        var unavailableResidentMemoryPIDs: [Int] = []

        mutating func append(_ process: CmuxTopProcessInfo) {
            guard seenProcessIds.insert(process.pid).inserted else { return }
            cpuPercent += process.cpuPercent
            memoryBytes = CmuxTopProcessSnapshot.clampedAdd(memoryBytes, process.memoryBytes)
            residentBytes = CmuxTopProcessSnapshot.clampedAdd(residentBytes, process.residentBytes)
            processIds.append(process.pid)
            if process.memorySource == .residentSize {
                memorySourceFallbackPIDs.append(process.pid)
            } else if process.memorySource == .unavailable {
                unavailableMemoryPIDs.append(process.pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                residentMemorySourceFallbackPIDs.append(process.pid)
            } else if process.residentMemorySource == .unavailable {
                unavailableResidentMemoryPIDs.append(process.pid)
            }
        }

        func payload() -> [String: Any] {
            let sortedProcessIds = processIds.sorted()
            return [
                "id": id,
                "name": title,
                "resources": CmuxTopResourceSummary(
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    residentBytes: residentBytes,
                    processCount: sortedProcessIds.count,
                    pids: sortedProcessIds,
                    memorySourceFallbackPIDs: memorySourceFallbackPIDs.sorted(),
                    residentMemorySourceFallbackPIDs: residentMemorySourceFallbackPIDs.sorted(),
                    unavailableMemoryPIDs: unavailableMemoryPIDs.sorted(),
                    unavailableResidentMemoryPIDs: unavailableResidentMemoryPIDs.sorted()
                ).payload()
            ]
        }
    }

    private struct CmuxCodingAgentProcessAggregate {
        let definition: CmuxTaskManagerCodingAgentDefinition
        var cpuPercent: Double = 0
        var memoryBytes: Int64 = 0
        var residentBytes: Int64 = 0
        var processIds: [Int] = []
        var seenProcessIds: Set<Int> = []
        var memorySourceFallbackPIDs: [Int] = []
        var residentMemorySourceFallbackPIDs: [Int] = []
        var unavailableMemoryPIDs: [Int] = []
        var unavailableResidentMemoryPIDs: [Int] = []

        mutating func append(_ process: CmuxTopProcessInfo) {
            guard seenProcessIds.insert(process.pid).inserted else { return }
            cpuPercent += process.cpuPercent
            memoryBytes = CmuxTopProcessSnapshot.clampedAdd(memoryBytes, process.memoryBytes)
            residentBytes = CmuxTopProcessSnapshot.clampedAdd(residentBytes, process.residentBytes)
            processIds.append(process.pid)
            if process.memorySource == .residentSize {
                memorySourceFallbackPIDs.append(process.pid)
            } else if process.memorySource == .unavailable {
                unavailableMemoryPIDs.append(process.pid)
            }
            if process.residentMemorySource == .rusageResidentSize {
                residentMemorySourceFallbackPIDs.append(process.pid)
            } else if process.residentMemorySource == .unavailable {
                unavailableResidentMemoryPIDs.append(process.pid)
            }
        }

        func payload() -> [String: Any] {
            let sortedProcessIds = processIds.sorted()
            return [
                "id": definition.id,
                "display_name": definition.displayName,
                "asset_name": definition.assetName ?? NSNull(),
                "resources": CmuxTopResourceSummary(
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    residentBytes: residentBytes,
                    processCount: sortedProcessIds.count,
                    pids: sortedProcessIds,
                    memorySourceFallbackPIDs: memorySourceFallbackPIDs.sorted(),
                    residentMemorySourceFallbackPIDs: residentMemorySourceFallbackPIDs.sorted(),
                    unavailableMemoryPIDs: unavailableMemoryPIDs.sorted(),
                    unavailableResidentMemoryPIDs: unavailableResidentMemoryPIDs.sorted()
                ).payload()
            ]
        }
    }

    private func processTreeNode(
        pid: Int,
        allowedPIDs: Set<Int>,
        rootPIDs: Set<Int>,
        visited: inout Set<Int>
    ) -> [String: Any]? {
        guard visited.insert(pid).inserted,
              let process = processesByPID[pid] else {
            return nil
        }

        let childNodes = (childrenByParentPID[pid] ?? [])
            .filter { allowedPIDs.contains($0) }
            .sorted { processSortKey($0) < processSortKey($1) }
            .compactMap {
                processTreeNode(
                    pid: $0,
                    allowedPIDs: allowedPIDs,
                    rootPIDs: rootPIDs,
                    visited: &visited
                )
            }

        var payload: [String: Any] = [
            "kind": "process",
            "pid": process.pid,
            "ppid": process.parentPID,
            "name": process.name,
            "path": process.path ?? NSNull(),
            "attribution_reason": attributionReason(for: process, allowedPIDs: allowedPIDs, rootPIDs: rootPIDs),
            "thread_count": process.threadCount,
            "memory_source": process.memorySource.rawValue,
            "resident_memory_source": process.residentMemorySource.rawValue,
            "resources": summary(for: [pid]).payload(),
            "children": childNodes
        ]
        if let ttyDevice = process.ttyDevice {
            payload["tty_device"] = ttyDevice
        } else {
            payload["tty_device"] = NSNull()
        }
        if let cmuxWorkspaceID = process.cmuxWorkspaceID {
            payload["cmux_workspace_id"] = cmuxWorkspaceID.uuidString
        } else {
            payload["cmux_workspace_id"] = NSNull()
        }
        if let cmuxSurfaceID = process.cmuxSurfaceID {
            payload["cmux_surface_id"] = cmuxSurfaceID.uuidString
        } else {
            payload["cmux_surface_id"] = NSNull()
        }
        if let processGroupID = process.processGroupID {
            payload["pgid"] = processGroupID
        } else {
            payload["pgid"] = NSNull()
        }
        if let terminalProcessGroupID = process.terminalProcessGroupID {
            payload["tpgid"] = terminalProcessGroupID
        } else {
            payload["tpgid"] = NSNull()
        }
        return payload
    }

    private func attributionReason(
        for process: CmuxTopProcessInfo,
        allowedPIDs: Set<Int>,
        rootPIDs: Set<Int>
    ) -> String {
        if let reason = process.cmuxAttributionReason {
            return reason
        }
        if rootPIDs.contains(process.pid), isWebKitWebContentProcess(process) {
            return "webview-root-pid"
        }
        if rootPIDs.contains(process.pid) {
            return "explicit-root-pid"
        }
        if allowedPIDs.contains(process.parentPID) {
            return "child-process"
        }
        return "included-process"
    }

    private func isWebKitWebContentProcess(_ process: CmuxTopProcessInfo) -> Bool {
        if process.name.localizedCaseInsensitiveContains("WebContent") {
            return true
        }
        return process.path?.localizedCaseInsensitiveContains("com.apple.WebKit.WebContent") == true
    }

    private func processSortKey(_ pid: Int) -> String {
        let process = processesByPID[pid]
        return "\(process?.name ?? ""):\(pid)"
    }

    private struct MemoryDiagnosticGroupAccumulator {
        let id: String
        let name: String
        var rssBytes: Int64 = 0
        var processIDs: [Int] = []
        var attributions: [CmuxTopProcessAttribution: MemoryDiagnosticAttributionAccumulator] = [:]

        mutating func append(
            process: CmuxTopProcessInfo,
            attribution: CmuxTopProcessAttribution?
        ) {
            rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
            processIDs.append(process.pid)
            guard let attribution else { return }
            if attributions[attribution] == nil {
                attributions[attribution] = MemoryDiagnosticAttributionAccumulator(attribution: attribution)
            }
            attributions[attribution]?.append(process: process)
        }

        func payload() -> [String: Any] {
            let sortedProcessIDs = processIDs.sorted()
            let attributionPayloads = attributions.values
                .sorted {
                    if $0.rssBytes != $1.rssBytes {
                        return $0.rssBytes > $1.rssBytes
                    }
                    return $0.displayKey < $1.displayKey
                }
                .map { $0.payload() }
            let topAttribution = attributionPayloads.first ?? NSNull()
            return [
                "id": id,
                "name": name,
                "rss_bytes": rssBytes,
                "resident_bytes": rssBytes,
                "process_count": sortedProcessIDs.count,
                "pids": sortedProcessIDs,
                "top_attribution": topAttribution,
                "attributions": attributionPayloads
            ]
        }
    }

    private struct MemoryDiagnosticAttributionAccumulator {
        let attribution: CmuxTopProcessAttribution
        var rssBytes: Int64 = 0
        var processIDs: [Int] = []

        var displayKey: String {
            [
                attribution.workspaceRef,
                attribution.paneRef,
                attribution.surfaceRef,
                attribution.workspaceID?.uuidString,
                attribution.paneID?.uuidString,
                attribution.surfaceID?.uuidString
            ]
                .compactMap { $0 }
                .joined(separator: "/")
        }

        mutating func append(process: CmuxTopProcessInfo) {
            rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
            processIDs.append(process.pid)
        }

        func payload() -> [String: Any] {
            var payload = attribution.payload()
            let sortedProcessIDs = processIDs.sorted()
            payload["rss_bytes"] = rssBytes
            payload["resident_bytes"] = rssBytes
            payload["process_count"] = sortedProcessIDs.count
            payload["pids"] = sortedProcessIDs
            return payload
        }
    }

    private func memoryDiagnosticGroups(
        for pids: Set<Int>,
        topGroupLimit: Int,
        attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> [[String: Any]] {
        var groups: [String: MemoryDiagnosticGroupAccumulator] = [:]
        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty ? "pid-\(pid)" : name
            let key = displayName.lowercased()
            if groups[key] == nil {
                groups[key] = MemoryDiagnosticGroupAccumulator(id: key, name: displayName)
            }
            groups[key]?.append(
                process: process,
                attribution: attributionByPID[pid] ?? nearestCMUXAttribution(for: pid)
            )
        }

        let limit = max(1, topGroupLimit)
        return groups.values
            .sorted {
                if $0.rssBytes != $1.rssBytes {
                    return $0.rssBytes > $1.rssBytes
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.payload() }
    }

    private func nearestCMUXAttribution(for pid: Int) -> CmuxTopProcessAttribution? {
        var visited: Set<Int> = []
        var currentPID = pid
        while currentPID > 0, visited.insert(currentPID).inserted {
            guard let process = processesByPID[currentPID] else { return nil }
            if process.cmuxWorkspaceID != nil || process.cmuxSurfaceID != nil {
                return CmuxTopProcessAttribution(
                    workspaceID: process.cmuxWorkspaceID,
                    workspaceRef: nil,
                    paneID: nil,
                    paneRef: nil,
                    surfaceID: process.cmuxSurfaceID,
                    surfaceRef: nil,
                    reason: process.cmuxAttributionReason ?? "cmux-process-scope"
                )
            }
            currentPID = process.parentPID
        }
        return nil
    }

    private func memoryDiagnosticSummaryText(
        appFootprintBytes: Int64,
        childRSSBytes: Int64,
        topGroup: [String: Any]?
    ) -> String {
        var summary = "\(Self.formatDiagnosticBytes(appFootprintBytes)) app footprint + \(Self.formatDiagnosticBytes(childRSSBytes)) child RSS"
        guard let topGroup,
              let name = topGroup["name"] as? String,
              let rssBytes = topGroup["rss_bytes"] as? Int64 ?? (topGroup["rss_bytes"] as? NSNumber)?.int64Value else {
            return summary
        }

        summary += "; top child group: \(name) \(Self.formatDiagnosticBytes(rssBytes))"
        if let attribution = topGroup["top_attribution"] as? [String: Any],
           let workspace = attribution["workspace_ref"] as? String ?? attribution["workspace_id"] as? String,
           !workspace.isEmpty {
            summary += " from workspace \(workspace)"
        }
        return summary
    }

    private static func formatDiagnosticBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private static func allProcesses(includeProcessDetails: Bool) -> [CmuxTopProcessInfo] {
        let sampledProcesses = allBSDProcesses()
        guard !sampledProcesses.isEmpty else { return [] }

        var scopeKeyByPID: [Int: CmuxTopProcessScopeCacheKey] = [:]
        scopeKeyByPID.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            scopeKeyByPID[Int(process.pbi_pid)] = scopeCacheKey(from: process)
        }
        let activeScopeKeys = Set(scopeKeyByPID.values)
        var parentScopeKeys: [CmuxTopProcessScopeCacheKey: CmuxTopProcessScopeCacheKey] = [:]
        parentScopeKeys.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            let key = scopeCacheKey(from: process)
            let parentPID = Int(process.pbi_ppid)
            guard let parentKey = scopeKeyByPID[parentPID] else { continue }
            parentScopeKeys[key] = parentKey
        }
        let sampledAtNanoseconds = cpuSampleClockNanoseconds()
        var currentCPUSamples: [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample] = [:]
        var processRecords: [(info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)] = []
        processRecords.reserveCapacity(sampledProcesses.count)
        for process in sampledProcesses {
            guard let processRecord = processInfo(
                from: process,
                includeProcessDetails: includeProcessDetails,
                sampledAtNanoseconds: sampledAtNanoseconds,
                currentCPUSamples: &currentCPUSamples
            ) else {
                continue
            }
            processRecords.append(processRecord)
        }
        let cpuPercentages = cpuPercentages(
            for: currentCPUSamples,
            activeKeys: activeScopeKeys,
            parentKeysByKey: parentScopeKeys,
            sampledAtNanoseconds: sampledAtNanoseconds
        )
        for index in processRecords.indices {
            guard let key = processRecords[index].cpuSampleKey,
                  let cpuPercent = cpuPercentages[key] else { continue }
            processRecords[index].info.cpuPercent = cpuPercent
        }
        pruneCMUXScopeCache(activeKeys: activeScopeKeys)
        return processRecords.map(\.info)
    }

    private static func processInfo(
        from bsdInfo: proc_bsdinfo,
        includeProcessDetails: Bool,
        sampledAtNanoseconds: UInt64,
        currentCPUSamples: inout [CmuxTopProcessScopeCacheKey: CmuxTopProcessCPUSample]
    ) -> (info: CmuxTopProcessInfo, cpuSampleKey: CmuxTopProcessScopeCacheKey?)? {
        let pid = Int(bsdInfo.pbi_pid)
        guard pid > 0 else { return nil }

        let taskInfo = taskInfo(for: pid)
        let resourceUsage = resourceUsage(for: pid)
        let cacheKey = scopeCacheKey(from: bsdInfo)
        let fallbackName = fixedString(bsdInfo.pbi_comm)
        let name = includeProcessDetails ? processName(pid: pid, fallback: fallbackName) : fallbackName
        let path = includeProcessDetails ? processPath(pid: pid) : nil
        let rawTTY = Int64(bsdInfo.e_tdev)
        let ttyDevice = rawTTY > 0 ? rawTTY : nil
        let cmuxScope = cachedCMUXScope(for: pid, cacheKey: cacheKey)
        let rawProcessGroupID = Int(bsdInfo.pbi_pgid)
        let processGroupID = rawProcessGroupID > 0 ? rawProcessGroupID : nil
        let rawTerminalProcessGroupID = Int(bsdInfo.e_tpgid)
        let terminalProcessGroupID = rawTerminalProcessGroupID > 0 ? rawTerminalProcessGroupID : nil
        let memoryBytes: Int64
        let memorySource: CmuxTopProcessMemorySource
        if let resourceUsage {
            memoryBytes = int64Clamped(resourceUsage.ri_phys_footprint)
            memorySource = .physicalFootprint
        } else if let taskInfo {
            memoryBytes = int64Clamped(taskInfo.pti_resident_size)
            memorySource = .residentSize
        } else {
            memoryBytes = 0
            memorySource = .unavailable
        }
        let residentBytes: Int64
        let residentMemorySource: CmuxTopProcessMemorySource
        if let taskInfo {
            residentBytes = int64Clamped(taskInfo.pti_resident_size)
            residentMemorySource = .residentSize
        } else if let resourceUsage {
            residentBytes = int64Clamped(resourceUsage.ri_resident_size)
            residentMemorySource = .rusageResidentSize
        } else {
            residentBytes = 0
            residentMemorySource = .unavailable
        }
        let cpuSampleKey: CmuxTopProcessScopeCacheKey?
        if let taskInfo {
            let currentCPUSample = cpuSample(from: taskInfo, sampledAtNanoseconds: sampledAtNanoseconds)
            currentCPUSamples[cacheKey] = currentCPUSample
            cpuSampleKey = cacheKey
        } else {
            cpuSampleKey = nil
        }

        return (CmuxTopProcessInfo(
            pid: pid,
            parentPID: Int(bsdInfo.pbi_ppid),
            name: name.isEmpty ? "pid-\(pid)" : name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: cmuxScope?.workspaceID,
            cmuxSurfaceID: cmuxScope?.surfaceID,
            cmuxAttributionReason: cmuxScope?.attributionReason,
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            memorySource: memorySource,
            residentBytes: residentBytes,
            residentMemorySource: residentMemorySource,
            virtualBytes: int64Clamped(taskInfo?.pti_virtual_size ?? 0),
            threadCount: Int(taskInfo?.pti_threadnum ?? 0)
        ), cpuSampleKey)
    }

    private static func allBSDProcesses() -> [proc_bsdinfo] {
        let pidStride = MemoryLayout<pid_t>.stride
        for _ in 0..<3 {
            let byteCount = Int(proc_listallpids(nil, 0))
            guard byteCount > 0 else { return [] }
            var pids = Array(repeating: pid_t(), count: max(1, byteCount / pidStride + 32))
            let returnedBytes = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count * pidStride))
            }
            guard returnedBytes >= 0 else { return [] }
            let count = min(pids.count, Int(returnedBytes) / pidStride)
            if count < pids.count {
                return pids.prefix(count).compactMap { pid in
                    guard pid > 0 else { return nil }
                    return bsdInfo(for: Int(pid))
                }
            }
        }
        return []
    }

    private static func bsdInfo(for pid: Int) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func deviceIdentifier(forTTYName ttyName: String) -> Int64? {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "not a tty" else {
            return nil
        }

        let path: String
        if trimmed.hasPrefix("/dev/") {
            path = trimmed
        } else {
            path = "/dev/\(trimmed)"
        }

        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            return nil
        }
        return Int64(statInfo.st_rdev)
    }

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }

    private static func taskInfo(for pid: Int) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTASKINFO, 0, &info, Int32(expectedSize))
        return size == expectedSize ? info : nil
    }

    private static func resourceUsage(for pid: Int) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // proc_pid_rusage imports as rusage_info_t *; callers pass the concrete
            // rusage struct address cast to that opaque buffer type.
            let buffer = baseAddress.assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(
                pid_t(pid),
                RUSAGE_INFO_V4,
                buffer
            )
        }
        return result == 0 ? info : nil
    }

    private static func processName(pid: Int, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN + 1))
        let length = proc_name(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: cmuxTopPIDPathBufferSize)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func fixedString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { rawBuffer in
            let endIndex = rawBuffer.firstIndex(of: 0) ?? rawBuffer.endIndex
            return String(decoding: rawBuffer[..<endIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func int64Clamped(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
