import CMUXAgentLaunch
import CmuxWorkspaces
import Darwin
import Foundation

// CmuxTopResourceSummary, CmuxTopProcessMemorySource, CmuxTopProcessInfo, and
// CmuxTopProcessScope are the process-monitoring value model and now live in the
// CMUXAgentLaunch package (imported above). This file keeps the
// CmuxTopProcessSnapshot orchestrator (synchronous OS sampling backed by
// process-wide CPU/scope/snapshot caches), which stays app-side.

nonisolated final class CmuxTopProcessSnapshot: @unchecked Sendable {
    let sampledAt: Date
    private let includesProcessDetails: Bool
    private let includesCMUXScope: Bool
    let processesByPID: [Int: CmuxTopProcessInfo]
    private let childrenByParentPID: [Int: [Int]]
    private let pidsByTTYDevice: [Int64: [Int]]
    private let pidsByCMUXSurfaceID: [UUID: [Int]]
    private let residentMemorySources: [CmuxTopProcessMemorySource]

    static func capture(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: allProcesses(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            ),
            sampledAt: Date(),
            includesProcessDetails: includeProcessDetails,
            includesCMUXScope: includeCMUXScope
        )
    }

    init(
        processes: [CmuxTopProcessInfo],
        sampledAt: Date,
        includesProcessDetails: Bool,
        includesCMUXScope: Bool = true
    ) {
        self.sampledAt = sampledAt
        self.includesProcessDetails = includesProcessDetails
        self.includesCMUXScope = includesCMUXScope
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
            "process_details": includesProcessDetails,
            "cmux_scope": includesCMUXScope
        ]
    }

    var hasCMUXScope: Bool {
        includesCMUXScope
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

    func cmuxScopedProcessIDsByPanelKey() -> [RestorableAgentSessionIndex.PanelKey: Set<Int>] {
        var processIDsByPanelKey: [RestorableAgentSessionIndex.PanelKey: Set<Int>] = [:]
        for process in cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID else {
                continue
            }
            let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            processIDsByPanelKey[key, default: []].insert(process.pid)
        }
        return processIDsByPanelKey
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
        var visited: Set<Int> = []
        var stack = childrenByParentPID[rootPID] ?? []
        stack.append(contentsOf: Self.listedChildPIDs(parentPID: rootPID))
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: childrenByParentPID[pid] ?? [])
            stack.append(contentsOf: Self.listedChildPIDs(parentPID: pid))
        }
        return result
    }

    private static func listedChildPIDs(parentPID: Int) -> [Int] {
        guard parentPID > 0 else { return [] }

        let pidStride = MemoryLayout<pid_t>.stride
        var capacity = 16
        var lastChildren: [Int] = []
        for _ in 0..<4 {
            var pids = Array(repeating: pid_t(), count: capacity)
            let returnedCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(
                    pid_t(parentPID),
                    buffer.baseAddress,
                    Int32(buffer.count * pidStride)
                )
            }
            guard returnedCount >= 0 else {
                return lastChildren
            }

            let count = min(pids.count, Int(returnedCount))
            lastChildren = pids
                .prefix(count)
                .compactMap { pid in
                    let intPID = Int(pid)
                    return intPID > 0 ? intPID : nil
                }
            if Int(returnedCount) < pids.count {
                return lastChildren
            }
            capacity = max(pids.count * 2, Int(returnedCount) + 16)
        }
        return lastChildren
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

    static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs {
            return Int64.max
        }
        return lhs + rhs
    }
}
