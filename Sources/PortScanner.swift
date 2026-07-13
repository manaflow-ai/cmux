import CmuxCore
import CmuxFoundation
import Foundation

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

    let commandRunner: any CommandRunning

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

    /// Monotonic revision per workspace for tracked agent PID changes.
    private var agentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var scanCoordination = PortScanCoordination()

    /// Workspaces with active agent PID tracking that need background rescans.
    private var trackedAgentWorkspaces: Set<UUID> = []
    private var lastAgentPortsByWorkspace: [UUID: [Int]] = [:]
    /// Stable publication state shared by every best-effort local scan path.
    private var panelPortSnapshot = PortScanSnapshotReconciler<PanelKey>()
    private var agentPortSnapshot = PortScanSnapshotReconciler<UUID>()
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

    init(commandRunner: any CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != ttyName else { return }
            panelPortSnapshot.remove(keys: [key])
            ttyNames[key] = ttyName
        }
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
            panelPortSnapshot.remove(keys: [key])
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

        guard scanCoordination.beginPanelScan() else { return }

        // Clear pending kicks — they're accounted for in this scan.
        pendingKicks.removeAll()

        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))
        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        let agentPIDsProvider = agentPIDsProvider
        let requestID = scanCoordination.makeRequestID()
        Task { [weak self] in
            guard let self else { return }
            let agentPIDsByWorkspace: [UUID: Set<Int>]
            if let agentPIDsProvider, !workspaceIds.isEmpty {
                agentPIDsByWorkspace = await MainActor.run {
                    agentPIDsProvider(workspaceIds)
                }
            } else {
                agentPIDsByWorkspace = [:]
            }
            await self.finishScan(
                panelSnapshot: panelSnapshot,
                agentPIDsByWorkspace: agentPIDsByWorkspace,
                agentRevisions: agentRevisions,
                requestID: requestID
            )
        }
    }

    private func finishScan(
        panelSnapshot: [PanelKey: String],
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        requestID: UInt64
    ) async {
        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))

        // Build TTY set (deduplicated).
        let uniqueTTYs = Set(panelSnapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // 1. ps -t tty1,tty2,... -o pid=,tty=
        async let agentProcessScanTask = expandAgentProcessTree(
            agentPIDsByWorkspace: agentPIDsByWorkspace
        )
        let psScan = ttyList.isEmpty
            ? (values: [Int: String](), completeness: PortScanCompleteness.complete)
            : await runPS(ttyList: ttyList)
        let agentProcessScan = await agentProcessScanTask
        let pidToTTY = psScan.values
        let agentPidToWorkspaces = agentProcessScan.values

        let allPids = Set(pidToTTY.keys).union(agentPidToWorkspaces.keys)
        guard !allPids.isEmpty else {
            let panelResults = panelSnapshot.map { ($0.key, [Int]()) }
            queue.async { [weak self] in
                self?.completePanelScan(
                    panelResults,
                    panelTTYs: panelSnapshot,
                    workspaceIds: workspaceIds,
                    agentPortsByWorkspace: [:],
                    agentRevisions: agentRevisions,
                    panelCompleteness: psScan.completeness,
                    agentCompleteness: agentProcessScan.completeness,
                    requestID: requestID
                )
            }
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidsCsv = allPids.sorted().map(String.init).joined(separator: ",")
        let lsofScan = await runLsof(pidsCsv: pidsCsv)
        let pidToPorts = lsofScan.values

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
        let panelResults = results
        let agentPortsSnapshot = agentPortsByWorkspace

        queue.async { [weak self] in
            self?.completePanelScan(
                panelResults,
                panelTTYs: panelSnapshot,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsSnapshot,
                agentRevisions: agentRevisions,
                panelCompleteness: Self.combinedCompleteness(psScan.completeness, lsofScan.completeness),
                agentCompleteness: Self.combinedCompleteness(agentProcessScan.completeness, lsofScan.completeness),
                requestID: requestID
            )
        }
    }

    private func completePanelScan(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        panelCompleteness: PortScanCompleteness,
        agentCompleteness: PortScanCompleteness,
        requestID: UInt64
    ) {
        let hasPendingScan = scanCoordination.finishPanelScan()
        deliverResults(
            panelResults,
            panelTTYs: panelTTYs,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            panelCompleteness: panelCompleteness,
            agentCompleteness: agentCompleteness,
            requestID: requestID
        )
        if hasPendingScan {
            runScan()
        }
    }

    private func refreshAgentPortsLocked(workspaceId: UUID, agentPIDs: Set<Int>) {
        let agentRevision = nextAgentRevision(for: workspaceId)
        let normalizedPIDs = Set(agentPIDs.filter { $0 > 0 })
        if normalizedPIDs.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
            scanCoordination.removeAgentWorkspaces([workspaceId])
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

        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        guard agentPIDsProvider != nil else {
            trackedAgentWorkspaces.removeAll()
            agentPortSnapshot.reset()
            updateAgentScanTimerLocked()
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions,
                completeness: .complete,
                requestID: scanCoordination.makeRequestID()
            )
            return
        }
        let request = AgentPortScanRequest(
            workspaceIds: workspaceIds,
            pidInput: .refreshProvider,
            agentRevisions: agentRevisions,
            requestID: scanCoordination.makeRequestID()
        )
        if let requestToStart = scanCoordination.enqueueAgentScan(request) {
            startAgentScan(requestToStart)
        }
    }

    private func scanAgentPorts(
        workspaceIds: Set<UUID>,
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard !workspaceIds.isEmpty else { return }
        let request = AgentPortScanRequest(
            workspaceIds: workspaceIds,
            pidInput: .captured(agentPIDsByWorkspace),
            agentRevisions: agentRevisions,
            requestID: scanCoordination.makeRequestID()
        )
        if let requestToStart = scanCoordination.enqueueAgentScan(request) {
            startAgentScan(requestToStart)
        }
    }

    private func startAgentScan(_ request: AgentPortScanRequest) {
        switch request.pidInput {
        case .refreshProvider:
            guard let agentPIDsProvider else {
                completeAgentScan(request, agentPortsByWorkspace: [:], completeness: .incomplete)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let agentPIDsByWorkspace = await MainActor.run {
                    agentPIDsProvider(request.workspaceIds)
                }
                self.queue.async { [weak self] in
                    self?.finishAgentPIDRefresh(request, agentPIDsByWorkspace: agentPIDsByWorkspace)
                }
            }
        case .captured:
            startAgentProcessScan(request)
        }
    }

    private func finishAgentPIDRefresh(
        _ request: AgentPortScanRequest,
        agentPIDsByWorkspace: [UUID: Set<Int>]
    ) {
        let resolution = request.resolvingPIDs(agentPIDsByWorkspace, currentRevisions: agentRevisionByWorkspace)
        let inactiveWorkspaceIds = resolution.inactiveWorkspaceIds
        if !inactiveWorkspaceIds.isEmpty {
            trackedAgentWorkspaces.subtract(inactiveWorkspaceIds)
            agentPortSnapshot.remove(keys: inactiveWorkspaceIds)
            scanCoordination.removeAgentWorkspaces(inactiveWorkspaceIds)
            forceAgentResultWorkspaces.formUnion(inactiveWorkspaceIds)
            updateAgentScanTimerLocked()
        }
        startAgentProcessScan(resolution.request)
    }
    private func startAgentProcessScan(_ request: AgentPortScanRequest) {
        guard case .captured(let agentPIDsByWorkspace) = request.pidInput else { return }
        Task { [weak self] in
            guard let self else { return }
            let agentProcessScan = await self.expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)
            let agentPidToWorkspaces = agentProcessScan.values
            guard !agentPidToWorkspaces.isEmpty else {
                self.queue.async { [weak self] in
                    self?.completeAgentScan(
                        request,
                        agentPortsByWorkspace: [:],
                        completeness: agentProcessScan.completeness
                    )
                }
                return
            }

            let pidsCsv = agentPidToWorkspaces.keys.sorted().map(String.init).joined(separator: ",")
            let lsofScan = await self.runLsof(pidsCsv: pidsCsv)
            let pidToPorts = lsofScan.values
            var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
            for (pid, ports) in pidToPorts {
                guard let workspaceIdsForPid = agentPidToWorkspaces[pid] else { continue }
                for targetWorkspaceId in workspaceIdsForPid {
                    agentPortsByWorkspace[targetWorkspaceId, default: []].formUnion(ports)
                }
            }
            let agentPortsSnapshot = agentPortsByWorkspace

            self.queue.async { [weak self] in
                self?.completeAgentScan(
                    request,
                    agentPortsByWorkspace: agentPortsSnapshot,
                    completeness: Self.combinedCompleteness(
                        agentProcessScan.completeness,
                        lsofScan.completeness
                    )
                )
            }
        }
    }

    private func completeAgentScan(
        _ request: AgentPortScanRequest,
        agentPortsByWorkspace: [UUID: Set<Int>],
        completeness: PortScanCompleteness
    ) {
        let pendingRequest = scanCoordination.finishAgentScan()
        deliverAgentResults(
            workspaceIds: request.workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: request.agentRevisions,
            completeness: completeness,
            requestID: request.requestID
        )
        if let pendingRequest {
            startAgentScan(pendingRequest)
        }
    }

    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        panelCompleteness: PortScanCompleteness,
        agentCompleteness: PortScanCompleteness,
        requestID: UInt64
    ) {
        if scanCoordination.shouldApplyPanelResult(requestID: requestID) {
            let scannedPorts = Dictionary(uniqueKeysWithValues: panelResults.filter { key, _ in
                ttyNames[key] == panelTTYs[key]
            })
            let trackedKeys = Set(ttyNames.keys)
            let stableSnapshot = panelPortSnapshot.reconcile(
                scannedPorts: scannedPorts,
                scannedKeys: Set(scannedPorts.keys),
                trackedKeys: trackedKeys,
                completeness: panelCompleteness
            )
            let panelCallback = onPortsUpdated
            if let panelCallback {
                Task { @MainActor in
                    for key in trackedKeys {
                        panelCallback(key.workspaceId, key.panelId, stableSnapshot[key] ?? [])
                    }
                }
            }
        }
        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            completeness: agentCompleteness,
            requestID: requestID
        )
    }

    private func deliverAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        completeness: PortScanCompleteness,
        requestID: UInt64
    ) {
        guard let agentCallback = onAgentPortsUpdated else { return }
        Task { [weak self] in
            guard let self else { return }
            let validatedResults = await self.validatedAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsByWorkspace,
                agentRevisions: agentRevisions,
                completeness: completeness,
                requestID: requestID
            )
            guard !validatedResults.isEmpty else { return }
            let appliedResults = await MainActor.run {
                validatedResults.filter { result in
                    agentCallback(result.workspaceId, result.ports)
                }
            }
            let appliedWorkspaceIds = Set(appliedResults.map(\.workspaceId))
            await self.acknowledgeAgentResults(validatedResults, appliedWorkspaceIds: appliedWorkspaceIds)
        }
    }

    private func acknowledgeAgentResults(
        _ results: [(workspaceId: UUID, ports: [Int], revision: UInt64, requestID: UInt64)],
        appliedWorkspaceIds: Set<UUID>
    ) async {
        guard !results.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                for (workspaceId, ports, revision, requestID) in results {
                    guard agentRevisionByWorkspace[workspaceId, default: 0] == revision else { continue }
                    guard scanCoordination.isLatestAgentResult(
                        workspaceId: workspaceId,
                        requestID: requestID
                    ) else { continue }
                    guard appliedWorkspaceIds.contains(workspaceId) else {
                        if !trackedAgentWorkspaces.contains(workspaceId) {
                            forceAgentResultWorkspaces.remove(workspaceId)
                            lastAgentPortsByWorkspace.removeValue(forKey: workspaceId)
                            scanCoordination.removeAgentWorkspaces([workspaceId])
                        }
                        continue
                    }
                    forceAgentResultWorkspaces.remove(workspaceId)
                    if ports.isEmpty, !trackedAgentWorkspaces.contains(workspaceId) {
                        lastAgentPortsByWorkspace.removeValue(forKey: workspaceId)
                        scanCoordination.removeAgentWorkspaces([workspaceId])
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
        agentRevisions: [UUID: UInt64],
        completeness: PortScanCompleteness,
        requestID: UInt64
    ) async -> [(workspaceId: UUID, ports: [Int], revision: UInt64, requestID: UInt64)] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var results: [(workspaceId: UUID, ports: [Int], revision: UInt64, requestID: UInt64)] = []
                let revisionMatchedWorkspaceIds = Set(workspaceIds.filter { workspaceId in
                    agentRevisionByWorkspace[workspaceId, default: 0] == agentRevisions[workspaceId, default: 0]
                })
                let validWorkspaceIds = scanCoordination.newAgentWorkspaces(
                    revisionMatchedWorkspaceIds,
                    eligibleWorkspaceIds: trackedAgentWorkspaces.union(forceAgentResultWorkspaces),
                    requestID: requestID
                )
                let scannedPorts = agentPortsByWorkspace
                    .filter { validWorkspaceIds.contains($0.key) }
                    .mapValues { Array($0) }
                let stableSnapshot = agentPortSnapshot.reconcile(
                    scannedPorts: scannedPorts,
                    scannedKeys: validWorkspaceIds,
                    trackedKeys: trackedAgentWorkspaces,
                    completeness: completeness
                )
                for workspaceId in workspaceIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let expectedRevision = agentRevisions[workspaceId, default: 0]
                    guard validWorkspaceIds.contains(workspaceId) else { continue }
                    let ports = stableSnapshot[workspaceId] ?? []
                    let previousPorts = lastAgentPortsByWorkspace[workspaceId]
                    if !forceAgentResultWorkspaces.contains(workspaceId) {
                        guard previousPorts != ports else { continue }
                        guard previousPorts != nil || !ports.isEmpty else { continue }
                    }
                    results.append((
                        workspaceId: workspaceId,
                        ports: ports,
                        revision: expectedRevision,
                        requestID: requestID
                    ))
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

}
