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
    @MainActor var onPortsUpdated: (@MainActor (_ workspaceId: UUID, _ panelId: UUID, _ ports: [Int]) -> Void)?
    /// Callback delivers workspace-scoped ports owned by tracked agents.
    @MainActor var onAgentPortsUpdated: (@MainActor (_ workspaceId: UUID, _ ports: [Int]) -> Bool)?
    // MARK: - State (all guarded by `queue`)

    let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)
    let processIdentityProvider: @Sendable (pid_t) -> AgentPIDProcessIdentity?
    let processPresenceProvider: @Sendable (pid_t) -> PIDPresence

    private var ttyNames: [PanelKey: String] = [:]
    private var panelRevisionByKey: [PanelKey: UInt64] = [:]

    var agentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var agentTrackingState = AgentPortTrackingState()
    var scanCoordination = PortScanCoordination()

    var trackedAgentWorkspaces: Set<UUID> = []
    var agentPublicationHistory = AgentPortPublicationHistory()
    /// Stable publication state shared by every best-effort local scan path.
    private var panelPortSnapshot = PortScanSnapshotReconciler<PanelKey>()
    var agentPortSnapshot = PortScanSnapshotReconciler<UUID>()
    var agentSnapshotReplacementState = AgentPortSnapshotReplacementState()
    var forceAgentResultWorkspaces: Set<UUID> = []
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
        },
        processPresenceProvider: @escaping @Sendable (pid_t) -> PIDPresence = {
            PIDPresence.current(pid: $0)
        }
    ) {
        self.commandRunner = commandRunner
        self.processIdentityProvider = processIdentityProvider
        self.processPresenceProvider = processPresenceProvider
    }

    @MainActor
    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let revision = publicationState.replacePanelLifecycle(key: key, ttyName: ttyName) else {
            return
        }
        queue.async { [self] in
            let previousTTY = ttyNames[key]
            panelPortSnapshot.remove(keys: [key])
            ttyNames[key] = ttyName
            panelRevisionByKey[key] = revision
            if previousTTY != nil {
                enqueuePanelPublication([
                    PanelPortScanPublication(key: key, ports: [], revision: revision)
                ])
            }
        }
    }

    @MainActor
    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
        publicationState.invalidatePanelLifecycle(for: key)
        queue.async { [self] in
            ttyNames.removeValue(forKey: key)
            panelRevisionByKey.removeValue(forKey: key)
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
        let normalizedRoots = Set(agentRoots.filter { $0.pid > 0 })
        let agentRevision = publicationState.replaceAgentLifecycle(
            workspaceId: workspaceId,
            roots: normalizedRoots
        )
        queue.async { [self] in
            refreshAgentPortsLocked(workspaceId: workspaceId, agentRoots: normalizedRoots, revision: agentRevision)
        }
    }

    @MainActor
    func unregisterAgentWorkspace(workspaceId: UUID) {
        _ = publicationState.invalidateAgentLifecycle(for: workspaceId)
        queue.async { [self] in
            agentRevisionByWorkspace.removeValue(forKey: workspaceId)
            _ = agentTrackingState.replaceRoots([], workspaceId: workspaceId)
            trackedAgentWorkspaces.remove(workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
            agentSnapshotReplacementState.cancel(workspaceId: workspaceId)
            forceAgentResultWorkspaces.remove(workspaceId)
            agentPublicationHistory.remove(workspaceId: workspaceId)
            scanCoordination.removeAgentWorkspaces([workspaceId])
            publicationBuffer.removeAgentWorkspace(workspaceId)
            updateAgentScanTimerLocked()
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
        let panelRevisions = panelSnapshot.keys.reduce(into: [PanelKey: UInt64]()) { result, key in
            result[key] = panelRevisionByKey[key]
        }
        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        let agentRootsByWorkspace = agentTrackingState.roots(for: workspaceIds)
        let requestID = scanCoordination.makeRequestID()
        Task { [weak self] in
            guard let self else { return }
            await self.finishScan(
                panelSnapshot: panelSnapshot,
                panelRevisions: panelRevisions,
                agentRootsByWorkspace: agentRootsByWorkspace,
                agentRevisions: agentRevisions,
                requestID: requestID
            )
        }
    }

    private func finishScan(
        panelSnapshot: [PanelKey: String],
        panelRevisions: [PanelKey: UInt64],
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
        let capturedPanelPIDs = capturePIDIdentities(Set(pidToTTY.keys))
        let capturedAgentPIDs = captureAgentPIDIdentities(
            ownershipByPID: agentProcessScan.values,
            workspaceIds: workspaceIds
        )
        let agentOwnershipBeforeLsof = capturedAgentPIDs.ownershipByPID
        let agentCompletenessBeforeLsof = combineAgentCompleteness(
            agentProcessScan.completenessByWorkspace,
            capturedAgentPIDs.completenessByWorkspace,
            workspaceIds: workspaceIds
        )

        let allPids = Set(capturedPanelPIDs.identitiesByPID.keys).union(agentOwnershipBeforeLsof.keys)
        guard !allPids.isEmpty else {
            let panelResults = panelSnapshot.map { ($0.key, [Int]()) }
            let panelLsofEvidence = PortLsofScanResult(
                values: [:],
                globallyComplete: true,
                incompletePIDs: capturedPanelPIDs.incompletePIDs
            )
            let panelCompletenessByKey = Self.panelCompletenessByKey(
                panelTTYs: panelSnapshot,
                pidToTTY: pidToTTY,
                psCompleteness: psScan.completeness,
                lsofScan: panelLsofEvidence
            )
            queue.async { [weak self] in
                self?.completePanelScan(
                    panelResults,
                    panelTTYs: panelSnapshot,
                    panelRevisions: panelRevisions,
                    workspaceIds: workspaceIds,
                    agentPortsByWorkspace: [:],
                    agentRevisions: agentRevisions,
                    panelCompletenessByKey: panelCompletenessByKey,
                    agentCompletenessByWorkspace: agentCompletenessBeforeLsof,
                    requestID: requestID
                )
            }
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidsCsv = allPids.sorted().map(String.init).joined(separator: ",")
        let lsofScan = await runLsof(pidsCsv: pidsCsv)
        let pidToPorts = lsofScan.values
        async let finalizedAgentPIDTask = finalizeAgentPIDOwnership(
            rootsByWorkspace: agentRootsByWorkspace,
            capturedOwnershipByPID: agentOwnershipBeforeLsof,
            capturedIdentitiesByPID: capturedAgentPIDs.identitiesByPID,
            workspaceIds: workspaceIds
        )
        let refreshedPanelProcessScan = capturedPanelPIDs.identitiesByPID.isEmpty
            ? (values: [Int: String](), completeness: PortScanCompleteness.complete)
            : await runPS(ttyList: ttyList)
        let revalidatedPanelPIDs = revalidatePanelPIDOwnership(
            capturedPIDToTTY: pidToTTY,
            capturedIdentitiesByPID: capturedPanelPIDs.identitiesByPID,
            refreshedPIDToTTY: refreshedPanelProcessScan.values
        )
        let validPIDToTTY = revalidatedPanelPIDs.values
        let finalizedAgentPIDs = await finalizedAgentPIDTask
        let agentOwnershipByPID = finalizedAgentPIDs.ownershipByPID

        // 3. Join: PID→TTY + PID→ports → TTY→ports
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = validPIDToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let ownership = agentOwnershipByPID[pid] else { continue }
            for workspaceId in ownership {
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
        let lsofAgentCompleteness = agentLsofCompleteness(
            ownershipByPID: agentOwnershipByPID,
            lsofScan: lsofScan,
            workspaceIds: workspaceIds
        )
        let agentCompletenessByWorkspace = combineAgentCompleteness(
            agentCompletenessBeforeLsof,
            combineAgentCompleteness(
                finalizedAgentPIDs.completenessByWorkspace,
                lsofAgentCompleteness,
                workspaceIds: workspaceIds
            ),
            workspaceIds: workspaceIds
        )
        let panelLsofEvidence = PortLsofScanResult(
            values: lsofScan.values,
            globallyComplete: lsofScan.globallyComplete,
            incompletePIDs: lsofScan.incompletePIDs
                .union(capturedPanelPIDs.incompletePIDs)
                .union(revalidatedPanelPIDs.incompletePIDs)
        )
        let panelCompletenessByKey = Self.panelCompletenessByKey(
            panelTTYs: panelSnapshot,
            pidToTTY: pidToTTY,
            psCompleteness: Self.combinedCompleteness(
                psScan.completeness,
                refreshedPanelProcessScan.completeness
            ),
            lsofScan: panelLsofEvidence
        )

        queue.async { [weak self] in
            self?.completePanelScan(
                panelResults,
                panelTTYs: panelSnapshot,
                panelRevisions: panelRevisions,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsSnapshot,
                agentRevisions: agentRevisions,
                panelCompletenessByKey: panelCompletenessByKey,
                agentCompletenessByWorkspace: agentCompletenessByWorkspace,
                requestID: requestID
            )
        }
    }

    private func completePanelScan(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        panelRevisions: [PanelKey: UInt64],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        panelCompletenessByKey: [PanelKey: PortScanCompleteness],
        agentCompletenessByWorkspace: [UUID: PortScanCompleteness],
        requestID: UInt64
    ) {
        let hasPendingScan = scanCoordination.finishPanelScan()
        deliverResults(
            panelResults,
            panelTTYs: panelTTYs,
            panelRevisions: panelRevisions,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            panelCompletenessByKey: panelCompletenessByKey,
            agentCompletenessByWorkspace: agentCompletenessByWorkspace,
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
        if agentTrackingState.replaceRoots(agentRoots, workspaceId: workspaceId),
           !agentRoots.isEmpty {
            agentSnapshotReplacementState.begin(workspaceId: workspaceId)
        }
        if agentRoots.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
            agentSnapshotReplacementState.cancel(workspaceId: workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
            scanCoordination.removeAgentWorkspaces([workspaceId])
            updateAgentScanTimerLocked()
            forceAgentResultWorkspaces.insert(workspaceId)
            deliverAgentResults(
                workspaceIds: [workspaceId],
                agentPortsByWorkspace: [:],
                agentRevisions: [workspaceId: revision],
                completenessByWorkspace: [workspaceId: .complete],
                requestID: scanCoordination.makeRequestID()
            )
            return
        }
        trackedAgentWorkspaces.insert(workspaceId)
        updateAgentScanTimerLocked()
        forceAgentResultWorkspaces.insert(workspaceId)

        scanAgentPorts(
            workspaceIds: [workspaceId],
            agentRootsByWorkspace: [workspaceId: agentRoots],
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
            let capturedAgentPIDs = self.captureAgentPIDIdentities(
                ownershipByPID: agentProcessScan.values,
                workspaceIds: request.workspaceIds
            )
            let agentCompletenessBeforeLsof = self.combineAgentCompleteness(
                agentProcessScan.completenessByWorkspace,
                capturedAgentPIDs.completenessByWorkspace,
                workspaceIds: request.workspaceIds
            )
            guard !capturedAgentPIDs.ownershipByPID.isEmpty else {
                self.queue.async { [weak self] in
                    self?.completeAgentScan(
                        request,
                        agentPortsByWorkspace: [:],
                        completenessByWorkspace: agentCompletenessBeforeLsof
                    )
                }
                return
            }

            let pidsCsv = capturedAgentPIDs.ownershipByPID.keys
                .sorted()
                .map(String.init)
                .joined(separator: ",")
            let lsofScan = await self.runLsof(pidsCsv: pidsCsv)
            let pidToPorts = lsofScan.values
            let finalizedAgentPIDs = await self.finalizeAgentPIDOwnership(
                rootsByWorkspace: agentRootsByWorkspace,
                capturedOwnershipByPID: capturedAgentPIDs.ownershipByPID,
                capturedIdentitiesByPID: capturedAgentPIDs.identitiesByPID,
                workspaceIds: request.workspaceIds
            )
            let agentOwnershipByPID = finalizedAgentPIDs.ownershipByPID
            var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
            for (pid, ports) in pidToPorts {
                guard let ownership = agentOwnershipByPID[pid] else { continue }
                for targetWorkspaceId in ownership {
                    agentPortsByWorkspace[targetWorkspaceId, default: []].formUnion(ports)
                }
            }
            let agentPortsSnapshot = agentPortsByWorkspace
            let lsofCompletenessByWorkspace = self.agentLsofCompleteness(
                ownershipByPID: agentOwnershipByPID,
                lsofScan: lsofScan,
                workspaceIds: request.workspaceIds
            )
            let completenessByWorkspace = self.combineAgentCompleteness(
                agentCompletenessBeforeLsof,
                self.combineAgentCompleteness(
                    finalizedAgentPIDs.completenessByWorkspace,
                    lsofCompletenessByWorkspace,
                    workspaceIds: request.workspaceIds
                ),
                workspaceIds: request.workspaceIds
            )

            self.queue.async { [weak self] in
                self?.completeAgentScan(
                    request,
                    agentPortsByWorkspace: agentPortsSnapshot,
                    completenessByWorkspace: completenessByWorkspace
                )
            }
        }
    }

    private func completeAgentScan(
        _ request: AgentPortScanRequest,
        agentPortsByWorkspace: [UUID: Set<Int>],
        completenessByWorkspace: [UUID: PortScanCompleteness]
    ) {
        let pendingRequest = scanCoordination.finishAgentScan()
        deliverAgentResults(
            workspaceIds: request.workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: request.agentRevisions,
            completenessByWorkspace: completenessByWorkspace,
            requestID: request.requestID
        )
        if let pendingRequest {
            startAgentScan(pendingRequest)
        }
    }

    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        panelRevisions: [PanelKey: UInt64],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        panelCompletenessByKey: [PanelKey: PortScanCompleteness],
        agentCompletenessByWorkspace: [UUID: PortScanCompleteness],
        requestID: UInt64
    ) {
        if scanCoordination.shouldApplyPanelResult(requestID: requestID) {
            let scannedPorts = Dictionary(uniqueKeysWithValues: panelResults.filter { key, _ in
                ttyNames[key] == panelTTYs[key]
                    && panelRevisionByKey[key] == panelRevisions[key]
            })
            let trackedKeys = Set(ttyNames.keys)
            let stableSnapshot = panelPortSnapshot.reconcile(
                scannedPorts: scannedPorts,
                scannedKeys: Set(scannedPorts.keys),
                trackedKeys: trackedKeys,
                completenessByKey: panelCompletenessByKey
            )
            let publications = scannedPorts.keys.compactMap { key -> PanelPortScanPublication? in
                guard let revision = panelRevisions[key] else { return nil }
                return PanelPortScanPublication(
                    key: key,
                    ports: stableSnapshot[key] ?? [],
                    revision: revision
                )
            }
            enqueuePanelPublication(publications)
        }
        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            completenessByWorkspace: agentCompletenessByWorkspace,
            requestID: requestID
        )
    }

    private func agentRevisionSnapshot(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
            partial[workspaceId] = agentRevisionByWorkspace[workspaceId, default: 0]
        }
    }

}
