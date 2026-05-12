import Combine
import Darwin
import Foundation
import Observation
import WebKit

/// Batched port scanner that replaces per-shell `ps + lsof` scanning.
///
/// Each shell sends a lightweight `report_tty` + `ports_kick` over the socket.
/// PortScanner coalesces kicks across all panels, then runs a single
/// `ps -t <ttys>` + `lsof -p <pids>` covering every panel that needs scanning.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds panel to `pendingKicks` set
/// 2. If no burst is active, starts a 200ms coalesce timer
/// 3. Coalesce fires → snapshots pending set → starts burst of 6 scans
/// 4. New kicks during burst merge into the active burst
/// 5. After last scan, if new kicks arrived, start a new coalesce cycle
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    /// Callback delivers `(workspaceId, panelId, ports)` on the main actor.
    var onPortsUpdated: (@MainActor (_ workspaceId: UUID, _ panelId: UUID, _ ports: [Int]) -> Void)?
    /// Callback delivers workspace-scoped ports owned by tracked agents.
    var onAgentPortsUpdated: (@MainActor (_ workspaceId: UUID, _ ports: [Int]) -> Void)?
    /// Provider returns tracked agent root PIDs for the given workspaces.
    var agentPIDsProvider: (@MainActor (_ workspaceIds: Set<UUID>) -> [UUID: Set<Int>])?

    // MARK: - State (all guarded by `queue`)

    private let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)

    /// TTY name per (workspace, panel).
    private var ttyNames: [PanelKey: String] = [:]

    /// Monotonic revision per workspace for tracked agent PID changes.
    private var agentRevisionByWorkspace: [UUID: UInt64] = [:]

    /// Workspaces with active agent PID tracking that need background rescans.
    private var trackedAgentWorkspaces: Set<UUID> = []

    /// Panels that requested a scan since the last coalesce snapshot.
    private var pendingKicks: Set<PanelKey> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Coalesce timer (200ms after first kick).
    private var coalesceTimer: DispatchSourceTimer?

    /// Periodic timer for agent-owned process trees that aren't attached to a TTY.
    private var agentScanTimer: DispatchSourceTimer?

    /// Burst scan offsets in seconds from the start of the burst.
    /// Each scan fires at this absolute offset; the recursive scheduler
    /// converts to relative delays between consecutive scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]
    private static let agentRescanInterval: TimeInterval = 2

    // MARK: - Public API

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != ttyName else { return }
            ttyNames[key] = ttyName
        }
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
        }
    }

    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)

            if !burstActive {
                startCoalesce()
            }
            // If burst is active, the next scan iteration will pick up the new kick.
        }
    }

    func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>) {
        queue.async { [self] in
            refreshAgentPortsLocked(workspaceId: workspaceId, agentPIDs: agentPIDs)
        }
    }

    // MARK: - Coalesce + Burst

    private func startCoalesce() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2)
        timer.setEventHandler { [weak self] in
            self?.coalesceTimerFired()
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func coalesceTimerFired() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        coalesceTimer = nil

        guard !pendingKicks.isEmpty else { return }
        burstActive = true
        runBurst(index: 0)
    }

    private func runBurst(index: Int, burstStart: DispatchTime? = nil) {
        // Already on `queue`.
        guard index < Self.burstOffsets.count else {
            burstActive = false
            // If new kicks arrived during the burst, start a new coalesce cycle.
            if !pendingKicks.isEmpty {
                startCoalesce()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + Self.burstOffsets[index]
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.runScan()
            self.runBurst(index: index + 1, burstStart: start)
        }
    }

    // MARK: - Scan

    private func runScan() {
        // Already on `queue`. Snapshot which panels to scan and their TTYs.
        // We scan all registered panels, not just pending ones, since ports can
        // appear/disappear on any panel.
        let panelSnapshot = ttyNames

        guard !panelSnapshot.isEmpty else {
            pendingKicks.removeAll()
            return
        }

        // Clear pending kicks — they're accounted for in this scan.
        pendingKicks.removeAll()

        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))
        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        guard let agentPIDsProvider, !workspaceIds.isEmpty else {
            finishScan(
                panelSnapshot: panelSnapshot,
                agentPIDsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let agentPIDsByWorkspace = await MainActor.run {
                agentPIDsProvider(workspaceIds)
            }
            self.queue.async { [weak self] in
                self?.finishScan(
                    panelSnapshot: panelSnapshot,
                    agentPIDsByWorkspace: agentPIDsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
    }

    private func finishScan(
        panelSnapshot: [PanelKey: String],
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        // Already on `queue`.
        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))

        // Build TTY set (deduplicated).
        let uniqueTTYs = Set(panelSnapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // 1. ps -t tty1,tty2,... -o pid=,tty=
        let pidToTTY = ttyList.isEmpty ? [:] : runPS(ttyList: ttyList)
        let agentPidToWorkspaces = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)

        let allPids = Set(pidToTTY.keys).union(agentPidToWorkspaces.keys)
        guard !allPids.isEmpty else {
            let panelResults = panelSnapshot.map { ($0.key, [Int]()) }
            deliverResults(
                panelResults,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidsCsv = allPids.sorted().map(String.init).joined(separator: ",")
        let pidToPorts = runLsof(pidsCsv: pidsCsv)

        // 3. Join: PID→TTY + PID→ports → TTY→ports
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = pidToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let workspaceIdsForPid = agentPidToWorkspaces[pid] else { continue }
            for workspaceId in workspaceIdsForPid {
                agentPortsByWorkspace[workspaceId, default: []].formUnion(ports)
            }
        }

        // 4. Map to per-panel port lists.
        var results: [(PanelKey, [Int])] = []
        for (key, tty) in panelSnapshot {
            let ports = portsByTTY[tty].map { Array($0).sorted() } ?? []
            results.append((key, ports))
        }

        deliverResults(
            results,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func refreshAgentPortsLocked(workspaceId: UUID, agentPIDs: Set<Int>) {
        let agentRevision = nextAgentRevision(for: workspaceId)
        let normalizedPIDs = Set(agentPIDs.filter { $0 > 0 })
        if normalizedPIDs.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
        } else {
            trackedAgentWorkspaces.insert(workspaceId)
        }
        updateAgentScanTimerLocked()

        scanAgentPorts(
            workspaceIds: [workspaceId],
            agentPIDsByWorkspace: normalizedPIDs.isEmpty ? [:] : [workspaceId: normalizedPIDs],
            agentRevisions: [workspaceId: agentRevision]
        )
    }

    private func updateAgentScanTimerLocked() {
        guard !trackedAgentWorkspaces.isEmpty else {
            agentScanTimer?.cancel()
            agentScanTimer = nil
            return
        }
        guard agentScanTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.agentRescanInterval,
            repeating: Self.agentRescanInterval
        )
        timer.setEventHandler { [weak self] in
            self?.runTrackedAgentScan()
        }
        agentScanTimer = timer
        timer.resume()
    }

    private func runTrackedAgentScan() {
        let workspaceIds = trackedAgentWorkspaces
        guard !workspaceIds.isEmpty else {
            updateAgentScanTimerLocked()
            return
        }

        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        guard let agentPIDsProvider else {
            trackedAgentWorkspaces.removeAll()
            updateAgentScanTimerLocked()
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let agentPIDsByWorkspace = await MainActor.run {
                agentPIDsProvider(workspaceIds)
            }
            self.queue.async { [weak self] in
                self?.finishTrackedAgentScan(
                    workspaceIds: workspaceIds,
                    agentPIDsByWorkspace: agentPIDsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
    }

    private func finishTrackedAgentScan(
        workspaceIds: Set<UUID>,
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        let normalizedPIDsByWorkspace = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        let inactiveWorkspaceIds = workspaceIds.subtracting(normalizedPIDsByWorkspace.keys)
        if !inactiveWorkspaceIds.isEmpty {
            trackedAgentWorkspaces.subtract(inactiveWorkspaceIds)
            updateAgentScanTimerLocked()
        }

        scanAgentPorts(
            workspaceIds: workspaceIds,
            agentPIDsByWorkspace: normalizedPIDsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func scanAgentPorts(
        workspaceIds: Set<UUID>,
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard !workspaceIds.isEmpty else { return }

        let agentPidToWorkspaces = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)
        guard !agentPidToWorkspaces.isEmpty else {
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        let pidsCsv = agentPidToWorkspaces.keys.sorted().map(String.init).joined(separator: ",")
        let pidToPorts = runLsof(pidsCsv: pidsCsv)
        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let workspaceIdsForPid = agentPidToWorkspaces[pid] else { continue }
            for targetWorkspaceId in workspaceIdsForPid {
                agentPortsByWorkspace[targetWorkspaceId, default: []].formUnion(ports)
            }
        }

        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        let panelCallback = onPortsUpdated
        if let panelCallback {
            Task { @MainActor in
                for (key, ports) in panelResults {
                    panelCallback(key.workspaceId, key.panelId, ports)
                }
            }
        }
        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func deliverAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard let agentCallback = onAgentPortsUpdated else { return }
        Task { [weak self] in
            guard let self else { return }
            let validatedResults = await self.validatedAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsByWorkspace,
                agentRevisions: agentRevisions
            )
            guard !validatedResults.isEmpty else { return }
            await MainActor.run {
                for (workspaceId, ports) in validatedResults {
                    agentCallback(workspaceId, ports)
                }
            }
        }
    }

    private func validatedAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) async -> [(UUID, [Int])] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var results: [(UUID, [Int])] = []
                for workspaceId in workspaceIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let currentRevision = agentRevisionByWorkspace[workspaceId, default: 0]
                    let expectedRevision = agentRevisions[workspaceId, default: 0]
                    guard currentRevision == expectedRevision else { continue }
                    let ports = Array(agentPortsByWorkspace[workspaceId] ?? []).sorted()
                    results.append((workspaceId, ports))
                }
                continuation.resume(returning: results)
            }
        }
    }

    private func agentRevisionSnapshot(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
            partial[workspaceId] = agentRevisionByWorkspace[workspaceId, default: 0]
        }
    }

    private func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        let nextRevision = agentRevisionByWorkspace[workspaceId, default: 0] &+ 1
        agentRevisionByWorkspace[workspaceId] = nextRevision
        return nextRevision
    }

    // MARK: - Process helpers

    static func captureStandardOutput(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        autoreleasepool {
            let process = Process()
            let stdoutPipe = Pipe()
            let stdoutReadHandle = stdoutPipe.fileHandleForReading
            let stdoutWriteHandle = stdoutPipe.fileHandleForWriting

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            defer {
                try? stdoutReadHandle.close()
                try? stdoutWriteHandle.close()
            }

            do {
                try process.run()
            } catch {
                return nil
            }

            // Close the parent's write end before reading. This is required:
            // readDataToEndOfFile() blocks until EOF, which only occurs when every
            // write-fd holder (parent + child) has closed its copy. Keeping the
            // parent's copy open would deadlock the read. The defer below is a
            // safety net for the error path (process.run() throws), not a
            // substitute for this explicit close.
            try? stdoutWriteHandle.close()
            let data = stdoutReadHandle.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            return output
        }
    }

    private func expandAgentProcessTree(agentPIDsByWorkspace: [UUID: Set<Int>]) -> [Int: Set<UUID>] {
        let normalizedRoots = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        guard !normalizedRoots.isEmpty else { return [:] }

        var pidToWorkspaces: [Int: Set<UUID>] = [:]
        var queue: [(pid: Int, workspaceId: UUID)] = []
        for (workspaceId, roots) in normalizedRoots {
            for pid in roots {
                if pidToWorkspaces[pid, default: []].insert(workspaceId).inserted {
                    queue.append((pid, workspaceId))
                }
            }
        }

        let parentByPid = runAllProcesses()
        guard !parentByPid.isEmpty else { return pidToWorkspaces }

        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPid) in parentByPid {
            childrenByParent[parentPid, default: []].append(pid)
        }

        var index = 0
        while index < queue.count {
            let (pid, workspaceId) = queue[index]
            index += 1

            for childPid in childrenByParent[pid] ?? [] {
                if pidToWorkspaces[childPid, default: []].insert(workspaceId).inserted {
                    queue.append((childPid, workspaceId))
                }
            }
        }

        return pidToWorkspaces
    }

    private func runPS(ttyList: String) -> [Int: String] {
        // `ps -t tty1,tty2,... -o pid=,tty=` — targeted scan, much cheaper than -ax.
        guard let output = Self.captureStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-t", ttyList, "-o", "pid=,tty="]
        ) else {
            return [:]
        }

        var mapping: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]) else { continue }
            mapping[pid] = String(parts[1])
        }
        return mapping
    }

    private func runAllProcesses() -> [Int: Int] {
        guard let output = Self.captureStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,ppid="]
        ) else {
            return [:]
        }

        var mapping: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]),
                  let parentPid = Int(parts[1]) else { continue }
            mapping[pid] = parentPid
        }
        return mapping
    }

    private func runLsof(pidsCsv: String) -> [Int: Set<Int>] {
        // `lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -F pn`
        guard let output = Self.captureStandardOutput(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return [:]
        }

        // Parse lsof -F output: lines starting with 'p' = PID, 'n' = name (host:port).
        var result: [Int: Set<Int>] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                // Strip remote endpoint if present.
                if let arrowIdx = name.range(of: "->") {
                    name = String(name[..<arrowIdx.lowerBound])
                }
                // Port is after the last colon.
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    // Strip anything non-numeric.
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = Int(cleaned), port > 0, port <= 65535 {
                        result[pid, default: []].insert(port)
                    }
                }
            default:
                break
            }
        }
        return result
    }
}

struct SidebarWorkspaceTrackedProcessSample: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let ttyDevice: UInt32?
    let residentBytes: UInt64
    let totalCPUTimeNanos: UInt64
}

struct SidebarWorkspaceResourceTrackingRoots: Equatable, Sendable {
    struct AgentRoot: Equatable, Sendable {
        let key: String
        let pid: Int32
    }

    let ttyDevices: Set<UInt32>
    let agentRoots: [AgentRoot]
    let browserRootPIDs: Set<Int32>
}

enum SidebarWorkspaceTrackedProcessKind: String, Equatable, Sendable {
    case shell
    case agent
    case languageServer
    case browser
    case helper
    case cmuxApp

    var localizedLabel: String {
        switch self {
        case .shell:
            return String(localized: "sidebar.resourceUsage.kind.shell", defaultValue: "Shell")
        case .agent:
            return String(localized: "sidebar.resourceUsage.kind.agent", defaultValue: "Agent")
        case .languageServer:
            return String(localized: "sidebar.resourceUsage.kind.languageServer", defaultValue: "Language Server")
        case .browser:
            return String(localized: "sidebar.resourceUsage.kind.browser", defaultValue: "Browser")
        case .helper:
            return String(localized: "sidebar.resourceUsage.kind.helper", defaultValue: "Helper")
        case .cmuxApp:
            return String(localized: "sidebar.resourceUsage.kind.cmuxApp", defaultValue: "cmux App")
        }
    }
}

struct SidebarWorkspaceProcessBreakdown: Equatable, Sendable {
    let pid: Int32
    let name: String
    let kind: SidebarWorkspaceTrackedProcessKind
    let residentBytes: UInt64
    let cpuPercent: Double
}

struct SidebarWorkspaceResourceUsageSnapshot: Equatable, Sendable {
    let residentBytes: UInt64
    let cpuPercent: Double
    let processes: [SidebarWorkspaceProcessBreakdown]
}

struct SidebarWorkspaceResourceResolution: Equatable, Sendable {
    let workspaces: [UUID: SidebarWorkspaceResourceUsageSnapshot]
    let total: SidebarWorkspaceResourceUsageSnapshot?
}

enum SidebarWorkspaceResourceResolver {
    private enum RootSource: Equatable {
        case tty
        case agent(key: String)
        case browser
        case app
    }

    private struct Ownership: Equatable {
        let rootPID: Int32
        let source: RootSource
    }

    static func resolve(
        workspaces: [UUID: SidebarWorkspaceResourceTrackingRoots],
        processes: [Int32: SidebarWorkspaceTrackedProcessSample],
        appPID: Int32,
        previousCPUTimeByPID: [Int32: UInt64],
        elapsedNanoseconds: UInt64
    ) -> SidebarWorkspaceResourceResolution {
        let childrenByParent = buildChildrenByParent(processes: processes)
        var workspaceSnapshots: [UUID: SidebarWorkspaceResourceUsageSnapshot] = [:]
        var workspaceOwnedPIDs: Set<Int32> = []
        var totalOwnershipByPID: [Int32: Ownership] = [:]

        for (workspaceID, roots) in workspaces {
            let ttyPIDs = processes.values
                .filter { sample in
                    guard let ttyDevice = sample.ttyDevice else { return false }
                    return roots.ttyDevices.contains(ttyDevice)
                }
                .map(\.pid)
            let ttyPIDSet = Set(ttyPIDs)
            let ttyRootPIDs = ttyPIDs.filter { pid in
                guard let sample = processes[pid] else { return false }
                return !ttyPIDSet.contains(sample.parentPID)
            }

            var ownershipByPID: [Int32: Ownership] = [:]
            var queue: [(pid: Int32, ownership: Ownership)] = []

            for pid in roots.browserRootPIDs.sorted() where processes[pid] != nil {
                queue.append((pid, Ownership(rootPID: pid, source: .browser)))
            }
            for agentRoot in roots.agentRoots.sorted(by: { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.pid < rhs.pid
            }) where processes[agentRoot.pid] != nil {
                queue.append((agentRoot.pid, Ownership(rootPID: agentRoot.pid, source: .agent(key: agentRoot.key))))
            }
            for pid in ttyRootPIDs.sorted() where processes[pid] != nil {
                queue.append((pid, Ownership(rootPID: pid, source: .tty)))
            }

            var index = 0
            while index < queue.count {
                let item = queue[index]
                index += 1

                guard ownershipByPID[item.pid] == nil else { continue }
                ownershipByPID[item.pid] = item.ownership

                for childPID in childrenByParent[item.pid] ?? [] {
                    queue.append((childPID, item.ownership))
                }
            }

            guard !ownershipByPID.isEmpty else { continue }

            let snapshot = buildSnapshot(
                processIDs: Set(ownershipByPID.keys),
                ownershipByPID: ownershipByPID,
                processes: processes,
                previousCPUTimeByPID: previousCPUTimeByPID,
                elapsedNanoseconds: elapsedNanoseconds
            )
            workspaceSnapshots[workspaceID] = snapshot
            workspaceOwnedPIDs.formUnion(ownershipByPID.keys)
            for (pid, ownership) in ownershipByPID {
                totalOwnershipByPID[pid] = ownership
            }
        }

        var totalPIDs = workspaceOwnedPIDs
        if processes[appPID] != nil {
            var queue: [Int32] = [appPID]
            var index = 0
            while index < queue.count {
                let pid = queue[index]
                index += 1
                guard totalPIDs.insert(pid).inserted else { continue }
                totalOwnershipByPID[pid] = totalOwnershipByPID[pid] ?? Ownership(rootPID: appPID, source: .app)
                for childPID in childrenByParent[pid] ?? [] {
                    queue.append(childPID)
                }
            }
        }

        let totalSnapshot = totalPIDs.isEmpty
            ? nil
            : buildSnapshot(
                processIDs: totalPIDs,
                ownershipByPID: totalOwnershipByPID,
                processes: processes,
                previousCPUTimeByPID: previousCPUTimeByPID,
                elapsedNanoseconds: elapsedNanoseconds
            )

        return SidebarWorkspaceResourceResolution(
            workspaces: workspaceSnapshots,
            total: totalSnapshot
        )
    }

    private static func buildChildrenByParent(
        processes: [Int32: SidebarWorkspaceTrackedProcessSample]
    ) -> [Int32: [Int32]] {
        processes.values.reduce(into: [Int32: [Int32]]()) { partial, process in
            partial[process.parentPID, default: []].append(process.pid)
        }
    }

    private static func buildSnapshot(
        processIDs: Set<Int32>,
        ownershipByPID: [Int32: Ownership],
        processes: [Int32: SidebarWorkspaceTrackedProcessSample],
        previousCPUTimeByPID: [Int32: UInt64],
        elapsedNanoseconds: UInt64
    ) -> SidebarWorkspaceResourceUsageSnapshot {
        let breakdown = processIDs.compactMap { pid -> SidebarWorkspaceProcessBreakdown? in
            guard let process = processes[pid],
                  let ownership = ownershipByPID[pid] else {
                return nil
            }
            return SidebarWorkspaceProcessBreakdown(
                pid: pid,
                name: process.name,
                kind: classify(process: process, ownership: ownership),
                residentBytes: process.residentBytes,
                cpuPercent: cpuPercent(
                    currentTotalCPUTimeNanos: process.totalCPUTimeNanos,
                    previousTotalCPUTimeNanos: previousCPUTimeByPID[pid],
                    elapsedNanoseconds: elapsedNanoseconds
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.residentBytes != rhs.residentBytes {
                return lhs.residentBytes > rhs.residentBytes
            }
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.pid < rhs.pid
        }

        return SidebarWorkspaceResourceUsageSnapshot(
            residentBytes: breakdown.reduce(0) { $0 + $1.residentBytes },
            cpuPercent: breakdown.reduce(0) { $0 + $1.cpuPercent },
            processes: breakdown
        )
    }

    private static func classify(
        process: SidebarWorkspaceTrackedProcessSample,
        ownership: Ownership
    ) -> SidebarWorkspaceTrackedProcessKind {
        switch ownership.source {
        case .browser:
            return process.pid == ownership.rootPID ? .browser : .helper
        case .agent:
            if process.pid == ownership.rootPID || isAgentLike(process.name) {
                return .agent
            }
            if isLanguageServer(process.name) {
                return .languageServer
            }
            return .helper
        case .tty:
            if process.pid == ownership.rootPID {
                if isAgentLike(process.name) {
                    return .agent
                }
                return isShellLike(process.name) ? .shell : .helper
            }
            if isLanguageServer(process.name) {
                return .languageServer
            }
            if isAgentLike(process.name) {
                return .agent
            }
            return .helper
        case .app:
            return process.pid == ownership.rootPID ? .cmuxApp : .helper
        }
    }

    private static func cpuPercent(
        currentTotalCPUTimeNanos: UInt64,
        previousTotalCPUTimeNanos: UInt64?,
        elapsedNanoseconds: UInt64
    ) -> Double {
        guard elapsedNanoseconds > 0 else { return 0 }
        guard let baseline = previousTotalCPUTimeNanos else { return 0 }
        let delta = currentTotalCPUTimeNanos >= baseline ? currentTotalCPUTimeNanos - baseline : 0
        return (Double(delta) / Double(elapsedNanoseconds)) * 100
    }

    private static func isShellLike(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return [
            "bash",
            "fish",
            "login",
            "nu",
            "sh",
            "ssh",
            "tmux",
            "zsh",
        ].contains(normalized)
    }

    private static func isAgentLike(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("claude")
            || normalized.contains("codex")
            || normalized.contains("cursor")
            || normalized.contains("gemini")
            || normalized.contains("opencode")
            || normalized.contains("aider")
    }

    private static func isLanguageServer(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("clangd")
            || normalized.contains("gopls")
            || normalized.contains("rust-analyzer")
            || normalized.contains("pyright")
            || normalized.contains("jdtls")
            || normalized.contains("tsserver")
            || normalized.contains("tailwindcss-language-server")
            || normalized.contains("language-server")
            || normalized.contains("langserver")
            || normalized.hasSuffix("lsp")
    }
}

private enum MachAbsoluteTimeConverter {
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(from ticks: UInt64) -> UInt64 {
        guard ticks > 0 else { return 0 }
        let numer = UInt64(timebaseInfo.numer)
        let denom = UInt64(timebaseInfo.denom)
        guard numer > 0, denom > 0 else { return ticks }
        guard numer != denom else { return ticks }

        let value = (Double(ticks) * Double(numer)) / Double(denom)
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value.rounded(.down))
    }
}

@MainActor
@Observable
final class SidebarWorkspaceResourceUsageStore {
    struct Snapshot: Equatable, Sendable {
        var workspaces: [UUID: SidebarWorkspaceResourceUsageSnapshot]
        var total: SidebarWorkspaceResourceUsageSnapshot?

        static let empty = Self(workspaces: [:], total: nil)
    }

    private struct WorkspaceDescriptor: Sendable {
        let ttyNames: Set<String>
        let agentRoots: [SidebarWorkspaceResourceTrackingRoots.AgentRoot]
        let browserRootPIDs: Set<Int32>
    }

    private struct SamplingContext: Sendable {
        let appPID: Int32
        let workspaces: [UUID: WorkspaceDescriptor]
        let previousCPUTimeByPID: [Int32: UInt64]
        let hasEstablishedCPUBaseline: Bool
        let elapsedNanoseconds: UInt64
    }

    private struct SamplingOutput: Sendable {
        let resolution: SidebarWorkspaceResourceResolution
        let trackedCPUTimeByPID: [Int32: UInt64]
    }

    private(set) var snapshot: Snapshot = .empty

    @ObservationIgnored private weak var tabManager: TabManager?
    @ObservationIgnored private var configuration = SidebarWorkspaceResourceUsageConfiguration.current()
    @ObservationIgnored private let samplingQueue = DispatchQueue(label: "com.cmux.sidebar-resource-usage", qos: .utility)
    @ObservationIgnored private var sampleLoopTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var previousCPUTimeByPID: [Int32: UInt64] = [:]
    @ObservationIgnored private var hasEstablishedCPUBaseline = false
    @ObservationIgnored private var lastSampleUptimeNanoseconds: UInt64?

    func bind(tabManager: TabManager, configuration: SidebarWorkspaceResourceUsageConfiguration) {
        self.tabManager = tabManager
        applyConfiguration(configuration)
    }

    func applyConfiguration(_ configuration: SidebarWorkspaceResourceUsageConfiguration) {
        generation &+= 1
        self.configuration = configuration

        stopSampleLoop()

        guard configuration.isEnabled else {
            previousCPUTimeByPID.removeAll()
            hasEstablishedCPUBaseline = false
            lastSampleUptimeNanoseconds = nil
            snapshot = .empty
            return
        }

        let currentGeneration = generation
        let intervalNanoseconds = Self.sampleIntervalNanoseconds(configuration.sampleInterval)
        sampleLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.performSample(generation: currentGeneration)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
                await self.performSample(generation: currentGeneration)
            }
        }
    }

    func stop() {
        generation &+= 1
        stopSampleLoop()
        previousCPUTimeByPID.removeAll()
        hasEstablishedCPUBaseline = false
        lastSampleUptimeNanoseconds = nil
        snapshot = .empty
    }

    private func stopSampleLoop() {
        sampleLoopTask?.cancel()
        sampleLoopTask = nil
    }

    private func performSample(generation: UInt64) async {
        let currentUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        guard let context = makeSamplingContext(
            generation: generation,
            currentUptimeNanoseconds: currentUptimeNanoseconds
        ) else {
            return
        }

        let samplingQueue = self.samplingQueue
        let output: SamplingOutput = await withCheckedContinuation { continuation in
            samplingQueue.async {
                continuation.resume(returning: Self.makeSamplingOutput(context: context))
            }
        }

        guard !Task.isCancelled, self.generation == generation else { return }
        previousCPUTimeByPID = output.trackedCPUTimeByPID
        hasEstablishedCPUBaseline = true
        lastSampleUptimeNanoseconds = currentUptimeNanoseconds
        let nextSnapshot = Snapshot(
            workspaces: output.resolution.workspaces,
            total: output.resolution.total
        )
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
        }
    }

    private static func sampleIntervalNanoseconds(_ interval: TimeInterval) -> UInt64 {
        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds > 0 else {
            return 1_000_000_000
        }
        if nanoseconds >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanoseconds.rounded(.up))
    }

    nonisolated private static func makeSamplingOutput(context: SamplingContext) -> SamplingOutput {
        // libproc/stat are blocking C APIs, so sampling runs on a dedicated queue
        // instead of occupying Swift's cooperative executor.
        let trackingRoots = resolveTrackingRoots(from: context.workspaces)
        let processCatalog = captureProcessCatalog()
        let nextCPUTimeByPID = processCatalog.reduce(into: [Int32: UInt64]()) { partial, item in
            partial[item.key] = item.value.totalCPUTimeNanos
        }
        let effectivePreviousCPU = context.hasEstablishedCPUBaseline
            ? context.previousCPUTimeByPID
            : nextCPUTimeByPID

        let resolution = SidebarWorkspaceResourceResolver.resolve(
            workspaces: trackingRoots,
            processes: processCatalog,
            appPID: context.appPID,
            previousCPUTimeByPID: effectivePreviousCPU,
            elapsedNanoseconds: context.elapsedNanoseconds
        )

        let trackedPIDs = Set(resolution.workspaces.values.flatMap { $0.processes.map(\.pid) })
            .union(resolution.total?.processes.map(\.pid) ?? [])
        let trackedCPUTimeByPID = trackedPIDs.reduce(into: [Int32: UInt64]()) { partial, pid in
            if let process = processCatalog[pid] {
                partial[pid] = process.totalCPUTimeNanos
            }
        }

        return SamplingOutput(
            resolution: resolution,
            trackedCPUTimeByPID: trackedCPUTimeByPID
        )
    }

    private func makeSamplingContext(
        generation: UInt64,
        currentUptimeNanoseconds: UInt64
    ) -> SamplingContext? {
        guard self.generation == generation,
              configuration.isEnabled,
              let tabManager else {
            return nil
        }

        let workspaces = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { workspace in
            let ttyNames = Set(workspace.surfaceTTYNames.values.compactMap(Self.normalizedTTYName))
            let agentRoots = workspace.agentPIDs.compactMap { item -> SidebarWorkspaceResourceTrackingRoots.AgentRoot? in
                guard item.value > 0 else { return nil }
                return SidebarWorkspaceResourceTrackingRoots.AgentRoot(key: item.key, pid: item.value)
            }
            let browserRootPIDs = Set(workspace.panels.values.flatMap { panel -> [Int32] in
                guard let browserPanel = panel as? BrowserPanel else { return [] }
                return Array(browserPanel.resourceUsageRootPIDs())
            })
            return (
                workspace.id,
                WorkspaceDescriptor(
                    ttyNames: ttyNames,
                    agentRoots: agentRoots,
                    browserRootPIDs: browserRootPIDs
                )
            )
        })

        let elapsedNanoseconds: UInt64 = {
            guard let lastSampleUptimeNanoseconds else {
                return UInt64(configuration.sampleInterval * 1_000_000_000)
            }
            let delta = currentUptimeNanoseconds &- lastSampleUptimeNanoseconds
            return max(delta, 1)
        }()

        return SamplingContext(
            appPID: Int32(ProcessInfo.processInfo.processIdentifier),
            workspaces: workspaces,
            previousCPUTimeByPID: previousCPUTimeByPID,
            hasEstablishedCPUBaseline: hasEstablishedCPUBaseline,
            elapsedNanoseconds: elapsedNanoseconds
        )
    }

    nonisolated private static func normalizedTTYName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/dev/") {
            let suffix = trimmed.dropFirst("/dev/".count)
            return suffix.isEmpty ? nil : String(suffix)
        }
        return trimmed
    }

    nonisolated private static func resolveTrackingRoots(
        from workspaces: [UUID: WorkspaceDescriptor]
    ) -> [UUID: SidebarWorkspaceResourceTrackingRoots] {
        workspaces.reduce(into: [UUID: SidebarWorkspaceResourceTrackingRoots]()) { partial, item in
            let ttyDevices = Set(item.value.ttyNames.compactMap(ttyDevice))
            partial[item.key] = SidebarWorkspaceResourceTrackingRoots(
                ttyDevices: ttyDevices,
                agentRoots: item.value.agentRoots,
                browserRootPIDs: item.value.browserRootPIDs
            )
        }
    }

    nonisolated private static func ttyDevice(for ttyName: String) -> UInt32? {
        let normalized = normalizedTTYName(ttyName)
        guard let normalized, !normalized.isEmpty else { return nil }
        let path = "/dev/\(normalized)"
        var fileInfo = stat()
        guard stat(path, &fileInfo) == 0 else { return nil }
        return UInt32(fileInfo.st_rdev)
    }

    nonisolated private static func captureProcessCatalog() -> [Int32: SidebarWorkspaceTrackedProcessSample] {
        var capacity = 4096
        var pids = [Int32](repeating: 0, count: capacity)
        var bytesWritten = 0

        while true {
            bytesWritten = Int(
                pids.withUnsafeMutableBytes { rawBuffer in
                    proc_listpids(
                        UInt32(bitPattern: PROC_ALL_PIDS),
                        0,
                        rawBuffer.baseAddress,
                        Int32(rawBuffer.count)
                    )
                }
            )
            guard bytesWritten > 0 else { return [:] }
            if bytesWritten < pids.count * MemoryLayout<Int32>.size {
                break
            }
            capacity *= 2
            pids = [Int32](repeating: 0, count: capacity)
        }

        let count = bytesWritten / MemoryLayout<Int32>.size
        let listedPIDs = pids.prefix(count)
        var results: [Int32: SidebarWorkspaceTrackedProcessSample] = [:]
        results.reserveCapacity(count)

        for pid in listedPIDs where pid > 0 {
            var bsdInfo = proc_bsdinfo()
            let bsdInfoSize = Int(
                withUnsafeMutableBytes(of: &bsdInfo) { rawBuffer in
                    proc_pidinfo(
                        pid,
                        PROC_PIDTBSDINFO,
                        0,
                        rawBuffer.baseAddress,
                        Int32(rawBuffer.count)
                    )
                }
            )
            guard bsdInfoSize == MemoryLayout<proc_bsdinfo>.size else { continue }

            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int(
                withUnsafeMutableBytes(of: &taskInfo) { rawBuffer in
                    proc_pidinfo(
                        pid,
                        PROC_PIDTASKINFO,
                        0,
                        rawBuffer.baseAddress,
                        Int32(rawBuffer.count)
                    )
                }
            )

            let residentBytes = taskInfoSize == MemoryLayout<proc_taskinfo>.size
                ? taskInfo.pti_resident_size
                : 0
            let totalCPUTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let totalCPUTimeNanos = taskInfoSize == MemoryLayout<proc_taskinfo>.size
                ? MachAbsoluteTimeConverter.nanoseconds(from: totalCPUTicks)
                : 0
            let name = string(from: bsdInfo.pbi_name).isEmpty
                ? string(from: bsdInfo.pbi_comm)
                : string(from: bsdInfo.pbi_name)
            let ttyFlags = UInt32(bitPattern: PROC_FLAG_CTTY | PROC_FLAG_CONTROLT)
            let ttyDevice = (bsdInfo.pbi_flags & ttyFlags) != 0
                ? bsdInfo.e_tdev
                : nil

            results[pid] = SidebarWorkspaceTrackedProcessSample(
                pid: pid,
                parentPID: Int32(bsdInfo.pbi_ppid),
                name: name,
                ttyDevice: ttyDevice,
                residentBytes: residentBytes,
                totalCPUTimeNanos: totalCPUTimeNanos
            )
        }

        return results
    }

    nonisolated private static func string<T>(from fixedCString: T) -> String {
        withUnsafeBytes(of: fixedCString) { rawBuffer in
            let bytes = Array(rawBuffer)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            guard length > 0 else { return "" }
            return String(decoding: bytes[..<length], as: UTF8.self)
        }
    }
}
