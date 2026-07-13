import CmuxCore
import CmuxFoundation
import Darwin
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
    // MARK: - State (all guarded by `queue`)

    let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)
    let processIdentityProvider: @Sendable (pid_t) -> AgentPIDProcessIdentity?

    private var ttyNames: [PanelKey: String] = [:]

    private var agentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var agentTrackingState = AgentPortTrackingState()
    private var scanCoordination = PortScanCoordination()

    private var trackedAgentWorkspaces: Set<UUID> = []
    private var agentPublicationHistory = AgentPortPublicationHistory()
    /// Stable publication state shared by every best-effort local scan path.
    private var panelPortSnapshot = PortScanSnapshotReconciler<PanelKey>()
    private var agentPortSnapshot = PortScanSnapshotReconciler<UUID>()
    private var agentSnapshotReplacementState = AgentPortSnapshotReplacementState()
    private var forceAgentResultWorkspaces: Set<UUID> = []
    private var trackedAgentScanningPaused = false
    let publicationState = PortScanPublicationState()
    var publicationBuffer = PortScanPublicationBuffer()

    private var pendingKicks: Set<PanelKey> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    private var coalesceTimer: DispatchSourceTimer?

    /// Periodic timer for agent-owned process trees that aren't attached to a TTY.
    private var agentScanTimer: DispatchSourceTimer?

    /// Each scan fires at this absolute offset; the recursive scheduler
    /// converts to relative delays between consecutive scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]
    private static let agentRescanInterval: TimeInterval = 2

    // MARK: - Public API

    init(
        commandRunner: any CommandRunning = CommandRunner(),
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        }
    ) {
        self.commandRunner = commandRunner
        self.processIdentityProvider = processIdentityProvider
    }

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            let previousTTY = ttyNames[key]
            guard previousTTY != ttyName else { return }
            panelPortSnapshot.remove(keys: [key])
            ttyNames[key] = ttyName
            if previousTTY != nil, onPortsUpdated != nil {
                let publication = ttyNames.keys.reduce(into: [PanelKey: [Int]]()) { result, panelKey in
                    result[panelKey] = panelPortSnapshot.snapshot[panelKey] ?? []
                }
                enqueuePanelPublication(publication)
            }
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
    @MainActor
    func refreshAgentPorts(workspaceId: UUID, agentRoots: Set<AgentPortRootIdentity>) {
        let agentRevision = publicationState.nextAgentRevision(for: workspaceId)
        queue.async { [self] in
            refreshAgentPortsLocked(workspaceId: workspaceId, agentRoots: agentRoots, revision: agentRevision)
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
        let agentRootsByWorkspace = agentTrackingState.roots(for: workspaceIds)
        let requestID = scanCoordination.makeRequestID()
        Task { [weak self] in
            guard let self else { return }
            await self.finishScan(
                panelSnapshot: panelSnapshot,
                agentRootsByWorkspace: agentRootsByWorkspace,
                agentRevisions: agentRevisions,
                requestID: requestID
            )
        }
    }

    private func finishScan(
        panelSnapshot: [PanelKey: String],
        agentRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>],
        agentRevisions: [UUID: UInt64],
        requestID: UInt64
    ) async {
        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))

        // Build TTY set (deduplicated).
        let uniqueTTYs = Set(panelSnapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // 1. ps -t tty1,tty2,... -o pid=,tty=
        async let agentProcessScanTask = expandAgentProcessTree(
            agentRootsByWorkspace: agentRootsByWorkspace
        )
        let psScan = ttyList.isEmpty
            ? (values: [Int: String](), completeness: PortScanCompleteness.complete)
            : await runPS(ttyList: ttyList)
        let agentProcessScan = await agentProcessScanTask
        let pidToTTY = psScan.values
        let revalidatedAgentProcessScan = revalidateAgentProcessTree(
            agentProcessScan.values,
            rootsByWorkspace: agentRootsByWorkspace
        )
        let agentPidToWorkspaces = revalidatedAgentProcessScan.values
        let agentTreeCompleteness = Self.combinedCompleteness(
            agentProcessScan.completeness,
            revalidatedAgentProcessScan.completeness
        )

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
                    agentCompleteness: agentTreeCompleteness,
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
                agentCompleteness: Self.combinedCompleteness(agentTreeCompleteness, lsofScan.completeness),
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

    private func refreshAgentPortsLocked(
        workspaceId: UUID,
        agentRoots: Set<AgentPortRootIdentity>,
        revision: UInt64
    ) {
        agentRevisionByWorkspace[workspaceId] = revision
        let normalizedRoots = Set(agentRoots.filter { $0.pid > 0 })
        if agentTrackingState.replaceRoots(normalizedRoots, workspaceId: workspaceId),
           !normalizedRoots.isEmpty {
            agentSnapshotReplacementState.begin(workspaceId: workspaceId)
        }
        if normalizedRoots.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
            agentSnapshotReplacementState.cancel(workspaceId: workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
            scanCoordination.removeAgentWorkspaces([workspaceId])
        } else {
            trackedAgentWorkspaces.insert(workspaceId)
        }
        updateAgentScanTimerLocked()
        forceAgentResultWorkspaces.insert(workspaceId)

        scanAgentPorts(
            workspaceIds: [workspaceId],
            agentRootsByWorkspace: normalizedRoots.isEmpty ? [:] : [workspaceId: normalizedRoots],
            agentRevisions: [workspaceId: revision]
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
        let request = AgentPortScanRequest(
            workspaceIds: workspaceIds,
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: agentTrackingState.roots(for: workspaceIds)
            ),
            agentRevisions: agentRevisions,
            requestID: scanCoordination.makeRequestID()
        )
        if let requestToStart = scanCoordination.enqueueAgentScan(request) {
            startAgentScan(requestToStart)
        }
    }

    private func scanAgentPorts(
        workspaceIds: Set<UUID>,
        agentRootsByWorkspace: [UUID: Set<AgentPortRootIdentity>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard !workspaceIds.isEmpty else { return }
        let request = AgentPortScanRequest(
            workspaceIds: workspaceIds,
            rootInput: AgentPortScanRootInput(rootsByWorkspace: agentRootsByWorkspace),
            agentRevisions: agentRevisions,
            requestID: scanCoordination.makeRequestID()
        )
        if let requestToStart = scanCoordination.enqueueAgentScan(request) {
            startAgentScan(requestToStart)
        }
    }

    private func startAgentScan(_ request: AgentPortScanRequest) {
        startAgentProcessScan(request)
    }
    private func startAgentProcessScan(_ request: AgentPortScanRequest) {
        let agentRootsByWorkspace = request.rootInput.rootsByWorkspace
        Task { [weak self] in
            guard let self else { return }
            let agentProcessScan = await self.expandAgentProcessTree(
                agentRootsByWorkspace: agentRootsByWorkspace
            )
            let revalidatedAgentProcessScan = self.revalidateAgentProcessTree(
                agentProcessScan.values,
                rootsByWorkspace: agentRootsByWorkspace
            )
            let agentPidToWorkspaces = revalidatedAgentProcessScan.values
            let agentTreeCompleteness = Self.combinedCompleteness(
                agentProcessScan.completeness,
                revalidatedAgentProcessScan.completeness
            )
            guard !agentPidToWorkspaces.isEmpty else {
                self.queue.async { [weak self] in
                    self?.completeAgentScan(
                        request,
                        agentPortsByWorkspace: [:],
                        completeness: agentTreeCompleteness
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
                        agentTreeCompleteness,
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
            if onPortsUpdated != nil {
                let publication = trackedKeys.reduce(into: [PanelKey: [Int]]()) { result, key in
                    result[key] = stableSnapshot[key] ?? []
                }
                enqueuePanelPublication(publication)
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
        guard onAgentPortsUpdated != nil else { return }
        let validatedResults = validatedAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            completeness: completeness,
            requestID: requestID
        )
        guard !validatedResults.isEmpty else { return }
        enqueueAgentPublication(validatedResults)
    }

    func acknowledgeAgentResults(
        _ results: [AgentPortScanPublication],
        appliedWorkspaceIds: Set<UUID>
    ) async -> [AgentPortScanPublication] {
        guard !results.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var completedLifecycles: [AgentPortScanPublication] = []
                let deliveredResults = publicationBuffer.completeAgentDelivery(results)
                for result in deliveredResults {
                    let workspaceId = result.workspaceId
                    guard agentRevisionByWorkspace[workspaceId, default: 0] == result.revision else {
                        agentPublicationHistory.reject(
                            workspaceId: workspaceId,
                            requestID: result.requestID
                        )
                        continue
                    }
                    let hasNewerPublication = publicationBuffer.hasPendingAgentPublication(
                        newerThan: result
                    )
                    guard appliedWorkspaceIds.contains(workspaceId) else {
                        agentPublicationHistory.reject(
                            workspaceId: workspaceId,
                            requestID: result.requestID
                        )
                        if !trackedAgentWorkspaces.contains(workspaceId), !hasNewerPublication {
                            forceAgentResultWorkspaces.remove(workspaceId)
                            agentPublicationHistory.remove(workspaceId: workspaceId)
                            scanCoordination.removeAgentWorkspaces([workspaceId])
                        }
                        if result.removesLifecycle, !hasNewerPublication {
                            completedLifecycles.append(result)
                        }
                        continue
                    }
                    if !hasNewerPublication {
                        forceAgentResultWorkspaces.remove(workspaceId)
                    }
                    if result.ports.isEmpty,
                       !trackedAgentWorkspaces.contains(workspaceId),
                       !hasNewerPublication {
                        agentPublicationHistory.remove(workspaceId: workspaceId)
                        scanCoordination.removeAgentWorkspaces([workspaceId])
                    } else {
                        agentPublicationHistory.acknowledge(
                            workspaceId: workspaceId,
                            ports: result.ports,
                            requestID: result.requestID
                        )
                    }
                    if result.removesLifecycle, !hasNewerPublication {
                        completedLifecycles.append(result)
                    }
                }
                continuation.resume(returning: completedLifecycles)
            }
        }
    }

    private func validatedAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        completeness: PortScanCompleteness,
        requestID: UInt64
    ) -> [AgentPortScanPublication] {
        var results: [AgentPortScanPublication] = []
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
        let replacementWorkspaces = agentSnapshotReplacementState.workspacesToReplace(
            from: validWorkspaceIds,
            completeness: completeness
        )
        agentPortSnapshot.remove(keys: replacementWorkspaces)
        let stableSnapshot = agentPortSnapshot.reconcile(
            scannedPorts: scannedPorts,
            scannedKeys: validWorkspaceIds,
            trackedKeys: trackedAgentWorkspaces,
            completeness: completeness
        )
        for workspaceId in validWorkspaceIds {
            let expectedRevision = agentRevisions[workspaceId, default: 0]
            let ports = stableSnapshot[workspaceId] ?? []
            let shouldPublish = agentPublicationHistory.shouldPublish(
                workspaceId: workspaceId,
                ports: ports,
                requestID: requestID,
                forced: forceAgentResultWorkspaces.contains(workspaceId)
            )
            guard shouldPublish else { continue }
            results.append(AgentPortScanPublication(
                workspaceId: workspaceId,
                ports: ports,
                revision: expectedRevision,
                requestID: requestID,
                removesLifecycle: !trackedAgentWorkspaces.contains(workspaceId)
            ))
        }
        return results
    }

    private func agentRevisionSnapshot(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
            partial[workspaceId] = agentRevisionByWorkspace[workspaceId, default: 0]
        }
    }

}
