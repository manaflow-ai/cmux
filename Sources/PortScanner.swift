import CmuxFoundation
import Foundation

/// Batched port scanner that replaces per-shell process + `lsof` scanning.
///
/// Each shell sends a lightweight `report_tty` + `ports_kick` over the socket.
/// PortScanner coalesces kicks across all panels, then runs one shared libproc
/// snapshot + `lsof -p <pids>` covering every panel that
/// needs scanning.
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
    var onAgentPortsUpdated: (@MainActor (_ workspaceId: UUID, _ ports: [Int]) -> Bool)?
    /// Provider returns tracked agent root PIDs for the given workspaces.
    var agentPIDsProvider: (@MainActor (_ workspaceIds: Set<UUID>) -> [UUID: Set<Int>])?

    // MARK: - State (all guarded by `queue`)

    private let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)

    /// TTY name per (workspace, panel).
    private var ttyNames: [PanelKey: String] = [:]

    /// Monotonic revision per workspace for tracked agent scan results.
    private var agentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var panelScanRevision: UInt64 = 0

    /// Workspaces with active agent PID tracking that need background rescans.
    private var trackedAgentWorkspaces: Set<UUID> = []
    private var lastAgentPortsByWorkspace: [UUID: [Int]] = [:]
    private var forceAgentResultWorkspaces: Set<UUID> = []
    private var trackedAgentScanningPaused = false

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

    func setTrackedAgentScanningPaused(_ paused: Bool) {
        queue.async { [self] in
            guard trackedAgentScanningPaused != paused else { return }
            trackedAgentScanningPaused = paused
            updateAgentScanTimerLocked()
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
        panelScanRevision &+= 1
        let scanRevision = panelScanRevision
        let agentRevisions = nextAgentRevisions(for: workspaceIds)
        guard let agentPIDsProvider, !workspaceIds.isEmpty else {
            finishScan(
                panelSnapshot: panelSnapshot,
                agentPIDsByWorkspace: [:],
                agentRevisions: agentRevisions,
                scanRevision: scanRevision
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
                    agentRevisions: agentRevisions,
                    scanRevision: scanRevision
                )
            }
        }
    }

    private func finishScan(
        panelSnapshot: [PanelKey: String],
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        scanRevision: UInt64
    ) {
        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
                requirements: .basic,
                maximumAge: 0.5,
                consumer: .portScannerPanel
            )
            let pidToTTY = Self.pidToTTY(
                panelSnapshot: panelSnapshot,
                processSnapshot: snapshot
            )
            let agentPidToWorkspaces = Self.expandAgentProcessTree(
                agentPIDsByWorkspace: agentPIDsByWorkspace,
                processSnapshot: snapshot
            )
            let allPIDs = Set(pidToTTY.keys).union(agentPidToWorkspaces.keys)
            let pidToPorts = await Task.detached(priority: .utility) {
                guard !allPIDs.isEmpty else { return [Int: Set<Int>]() }
                return Self.runLsof(pids: allPIDs)
            }.value
#if DEBUG
            let filterMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
                .portFilter,
                inputCount: pidToPorts.count
            )
#endif
            let scanResult = Self.scanResult(
                panelSnapshot: panelSnapshot,
                pidToTTY: pidToTTY,
                agentPidToWorkspaces: agentPidToWorkspaces,
                pidToPorts: pidToPorts
            )
#if DEBUG
            ProcessPerformanceMetrics.shared.operationCompleted(
                filterMetricsToken,
                outputCount: scanResult.panelResults.count + scanResult.agentPortsByWorkspace.count
            )
#endif
            self.queue.async { [weak self] in
                guard let self else { return }
                guard Self.acceptsResult(
                    currentRevision: self.panelScanRevision,
                    expectedRevision: scanRevision,
                    staleMetric: .portPanelRevision
                ) else { return }
                let livePanelResults = scanResult.panelResults.filter { key, _ in
                    self.ttyNames[key] == panelSnapshot[key]
                }
                self.deliverResults(
                    livePanelResults,
                    workspaceIds: workspaceIds,
                    agentPortsByWorkspace: scanResult.agentPortsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
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
        forceAgentResultWorkspaces.insert(workspaceId)

        scanAgentPorts(
            workspaceIds: [workspaceId],
            agentPIDsByWorkspace: normalizedPIDs.isEmpty ? [:] : [workspaceId: normalizedPIDs],
            agentRevisions: [workspaceId: agentRevision]
        )
    }

    private func updateAgentScanTimerLocked() {
        guard !trackedAgentScanningPaused, !trackedAgentWorkspaces.isEmpty else {
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

        let agentRevisions = nextAgentRevisions(for: workspaceIds)
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
            forceAgentResultWorkspaces.formUnion(inactiveWorkspaceIds)
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

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await CmuxTopProcessSnapshotStore.shared.snapshot(
                requirements: .basic,
                maximumAge: 0.5,
                consumer: .portScannerAgent
            )
            let agentPidToWorkspaces = Self.expandAgentProcessTree(
                agentPIDsByWorkspace: agentPIDsByWorkspace,
                processSnapshot: snapshot
            )
            let pidToPorts = await Task.detached(priority: .utility) {
                Self.runLsof(pids: Set(agentPidToWorkspaces.keys))
            }.value
#if DEBUG
            let filterMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
                .portFilter,
                inputCount: pidToPorts.count
            )
#endif
            let agentPortsByWorkspace = Self.agentPortsByWorkspace(
                agentPidToWorkspaces: agentPidToWorkspaces,
                pidToPorts: pidToPorts
            )
#if DEBUG
            ProcessPerformanceMetrics.shared.operationCompleted(
                filterMetricsToken,
                outputCount: agentPortsByWorkspace.count
            )
#endif
            self.queue.async { [weak self] in
                self?.deliverAgentResults(
                    workspaceIds: workspaceIds,
                    agentPortsByWorkspace: agentPortsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
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
#if DEBUG
                let applyMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
                    .portApply,
                    inputCount: panelResults.count
                )
#endif
                for (key, ports) in panelResults {
                    panelCallback(key.workspaceId, key.panelId, ports)
                }
#if DEBUG
                ProcessPerformanceMetrics.shared.operationCompleted(
                    applyMetricsToken,
                    outputCount: panelResults.count
                )
#endif
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
#if DEBUG
            let applyMetricsToken = ProcessPerformanceMetrics.shared.operationStarted(
                .portApply,
                inputCount: validatedResults.count
            )
#endif
            let appliedResults = await MainActor.run {
                validatedResults.filter { result in
                    agentCallback(result.workspaceId, result.ports)
                }
            }
#if DEBUG
            ProcessPerformanceMetrics.shared.operationCompleted(
                applyMetricsToken,
                outputCount: appliedResults.count
            )
#endif
            await self.acknowledgeAgentResults(
                validatedResults,
                appliedWorkspaceIds: Set(appliedResults.map(\.workspaceId))
            )
        }
    }

    private func acknowledgeAgentResults(
        _ results: [(workspaceId: UUID, ports: [Int], revision: UInt64)],
        appliedWorkspaceIds: Set<UUID>
    ) async {
        guard !results.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                for (workspaceId, ports, revision) in results {
                    guard Self.acceptsResult(
                        currentRevision: agentRevisionByWorkspace[workspaceId, default: 0],
                        expectedRevision: revision,
                        staleMetric: .portAgentAcknowledgement
                    ) else { continue }
                    guard appliedWorkspaceIds.contains(workspaceId) else {
                        if !trackedAgentWorkspaces.contains(workspaceId) {
                            forceAgentResultWorkspaces.remove(workspaceId)
                            lastAgentPortsByWorkspace.removeValue(forKey: workspaceId)
                        }
                        continue
                    }
                    forceAgentResultWorkspaces.remove(workspaceId)
                    if ports.isEmpty, !trackedAgentWorkspaces.contains(workspaceId) {
                        lastAgentPortsByWorkspace.removeValue(forKey: workspaceId)
                    } else {
                        lastAgentPortsByWorkspace[workspaceId] = ports
                    }
                }
                continuation.resume()
            }
        }
    }

    private func validatedAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) async -> [(workspaceId: UUID, ports: [Int], revision: UInt64)] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var results: [(workspaceId: UUID, ports: [Int], revision: UInt64)] = []
                for workspaceId in workspaceIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let expectedRevision = agentRevisions[workspaceId, default: 0]
                    guard Self.acceptsResult(
                        currentRevision: agentRevisionByWorkspace[workspaceId, default: 0],
                        expectedRevision: expectedRevision,
                        staleMetric: .portAgentRevision
                    ) else { continue }
                    let ports = Array(agentPortsByWorkspace[workspaceId] ?? []).sorted()
                    let previousPorts = lastAgentPortsByWorkspace[workspaceId]
                    if !forceAgentResultWorkspaces.contains(workspaceId) {
                        guard previousPorts != ports else { continue }
                        guard previousPorts != nil || !ports.isEmpty else { continue }
                    }
                    results.append((workspaceId: workspaceId, ports: ports, revision: expectedRevision))
                }
                continuation.resume(returning: results)
            }
        }
    }

    private func nextAgentRevisions(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
            partial[workspaceId] = nextAgentRevision(for: workspaceId)
        }
    }

    private func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        let nextRevision = agentRevisionByWorkspace[workspaceId, default: 0] &+ 1
        agentRevisionByWorkspace[workspaceId] = nextRevision
        return nextRevision
    }

#if DEBUG
    static func acceptsResult(
        currentRevision: UInt64,
        expectedRevision: UInt64,
        staleMetric: ProcessStaleRejection,
        metrics: ProcessPerformanceMetrics = .shared
    ) -> Bool {
        guard currentRevision == expectedRevision else {
            metrics.recordStaleRejection(staleMetric)
            return false
        }
        return true
    }
#else
    static func acceptsResult(
        currentRevision: UInt64,
        expectedRevision: UInt64,
        staleMetric: ProcessStaleRejection
    ) -> Bool {
        currentRevision == expectedRevision
    }
#endif

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
            // The pipe reader blocks until EOF, which only occurs when every
            // write-fd holder (parent + child) has closed its copy. Keeping the
            // parent's copy open would deadlock the read. The defer below is a
            // safety net for the error path (process.run() throws), not a
            // substitute for this explicit close.
            try? stdoutWriteHandle.close()
            let data = stdoutReadHandle.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            return output
        }
    }

    static func expandAgentProcessTree(
        agentPIDsByWorkspace: [UUID: Set<Int>],
        processSnapshot: CmuxTopProcessSnapshot
    ) -> [Int: Set<UUID>] {
        let normalizedRoots = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        guard !normalizedRoots.isEmpty else { return [:] }

        var pidToWorkspaces: [Int: Set<UUID>] = [:]
        for (workspaceId, roots) in normalizedRoots {
            for pid in processSnapshot.expandedPIDs(rootPIDs: roots) {
                pidToWorkspaces[pid, default: []].insert(workspaceId)
            }
        }
        return pidToWorkspaces
    }

    private static func pidToTTY(
        panelSnapshot: [PanelKey: String],
        processSnapshot: CmuxTopProcessSnapshot
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        for tty in Set(panelSnapshot.values) {
            for pid in processSnapshot.pids(forTTYName: tty) {
                result[pid] = tty
            }
        }
        return result
    }

    private static func scanResult(
        panelSnapshot: [PanelKey: String],
        pidToTTY: [Int: String],
        agentPidToWorkspaces: [Int: Set<UUID>],
        pidToPorts: [Int: Set<Int>]
    ) -> (panelResults: [(PanelKey, [Int])], agentPortsByWorkspace: [UUID: Set<Int>]) {
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            if let tty = pidToTTY[pid] {
                portsByTTY[tty, default: []].formUnion(ports)
            }
        }
        let panelResults = panelSnapshot.map { key, tty in
            (key, Array(portsByTTY[tty] ?? []).sorted())
        }
        return (
            panelResults,
            agentPortsByWorkspace(
                agentPidToWorkspaces: agentPidToWorkspaces,
                pidToPorts: pidToPorts
            )
        )
    }

    private static func agentPortsByWorkspace(
        agentPidToWorkspaces: [Int: Set<UUID>],
        pidToPorts: [Int: Set<Int>]
    ) -> [UUID: Set<Int>] {
        var result: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            for workspaceID in agentPidToWorkspaces[pid] ?? [] {
                result[workspaceID, default: []].formUnion(ports)
            }
        }
        return result
    }

    private static func runLsof(pids: Set<Int>) -> [Int: Set<Int>] {
        guard !pids.isEmpty else { return [:] }
#if DEBUG
        let metricsToken = ProcessPerformanceMetrics.shared.lsofStarted(pidCount: pids.count)
        defer { ProcessPerformanceMetrics.shared.lsofCompleted(metricsToken) }
#endif
        let pidsCSV = pids.sorted().map(String.init).joined(separator: ",")
        // `lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -F pn`
        guard let output = captureStandardOutput(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", pidsCSV, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return [:]
        }

        return parseLsofOutput(output)
    }

    static func parseLsofOutput(_ output: String) -> [Int: Set<Int>] {
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
