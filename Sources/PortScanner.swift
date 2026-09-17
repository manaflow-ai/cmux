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
/// 4. New kicks during a burst require three later scan attempts
/// 5. After the last scan, start a follow-up burst if the active burst did not
///    have three attempts left for the most recent kick
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
    @MainActor let ttySessionIdentityProvider: @MainActor @Sendable (String) -> TerminalTTYSessionIdentity?

    private var ttyNames: [PanelKey: String] = [:]
    private var panelRevisionByKey: [PanelKey: UInt64] = [:]

    var agentRevisionByWorkspace: [UUID: UInt64] = [:]
    private var agentTrackingState = AgentPortTrackingState()
    var scanCoordination = PortScanCoordination()

    var trackedAgentWorkspaces: Set<UUID> = []
    var agentPublicationHistory = AgentPortPublicationHistory()
    /// Stable publication state shared by every best-effort local scan path.
    private var panelPortSnapshot = PortScanSnapshotReconciler<PanelKey>(
        missingPortRetentionLimit: PortScanner.panelMissingPortRetentionLimit
    )
    var agentPortSnapshot = PortScanSnapshotReconciler<UUID>()
    /// Last known listener identities for each published panel port. These
    /// identities let a later scan retire a port even when an unrelated PID
    /// makes the enclosing process-tree scan incomplete.
    private var panelPortOwnersByKey: [PanelKey: [Int: Set<AgentPIDProcessIdentity>]] = [:]
    /// Last known listener identities for each published agent port.
    var agentPortOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]] = [:]
    var agentSnapshotReplacementState = AgentPortSnapshotReplacementState()
    var forceAgentResultWorkspaces: Set<UUID> = []
    private var trackedAgentScanningPaused = false
    let publicationState = PortScanPublicationState()
    var publicationBuffer = PortScanPublicationBuffer()

    private var pendingKicks: Set<PanelKey> = []

    /// Scan attempts still owed to the most recent kick. This keeps scheduling
    /// coupled to the panel reconciler's complete-miss retention policy.
    private var scansRemainingForPendingKicks = 0

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Generation invalidates callbacks that were queued before a panel
    /// lifecycle changed. The queue is the sole owner, so cancellation and
    /// generation checks are deterministic and race-free.
    private var burstGeneration: UInt64 = 0
    private var scheduledBurstTimers: [UUID: DispatchSourceTimer] = [:]

    private var coalesceTimer: DispatchSourceTimer?

    /// Periodic timer for agent-owned process trees that aren't attached to a TTY.
    private var agentScanTimer: DispatchSourceTimer?

    /// Each scan fires at this absolute offset; the recursive scheduler
    /// converts to relative delays between consecutive scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]
    private static let panelMissingPortRetentionLimit = 2
    private static let minimumScansPerKick = panelMissingPortRetentionLimit + 1
    private static let agentRescanInterval: TimeInterval = 2

    // MARK: - Public API

    init(
        commandRunner: any CommandRunning = CommandRunner(),
        processIdentityProvider: @escaping @Sendable (pid_t) -> AgentPIDProcessIdentity? = {
            AgentPIDProcessIdentity(pid: $0)
        },
        processPresenceProvider: @escaping @Sendable (pid_t) -> PIDPresence = {
            PIDPresence.current(pid: $0)
        },
        ttySessionIdentityProvider: @escaping @MainActor @Sendable (String) -> TerminalTTYSessionIdentity? = {
            TerminalTTYSessionIdentity(ttyName: $0)
        }
    ) {
        self.commandRunner = commandRunner
        self.processIdentityProvider = processIdentityProvider
        self.processPresenceProvider = processPresenceProvider
        self.ttySessionIdentityProvider = ttySessionIdentityProvider
    }

    /// Registers or replaces a panel's TTY lifecycle and clears its prior port ownership.
    @MainActor
    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let revision = publicationState.replacePanelLifecycle(
            key: key,
            ttyName: ttyName,
            sessionIdentity: ttySessionIdentityProvider(ttyName)
        ) else {
            return
        }
        let scanTTYName = Self.canonicalTTYName(ttyName)
        queue.async { [self] in
            let previousTTY = ttyNames[key]
            panelPortSnapshot.remove(keys: [key])
            panelPortOwnersByKey.removeValue(forKey: key)
            ttyNames[key] = scanTTYName
            panelRevisionByKey[key] = revision
            if previousTTY != nil {
                enqueuePanelPublication([
                    PanelPortScanPublication(key: key, ports: [], revision: revision)
                ])
            }
        }
    }

    /// Stops tracking a panel and removes its published ports and owner evidence.
    @MainActor
    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
        publicationState.invalidatePanelLifecycle(for: key)
        queue.async { [self] in
            ttyNames.removeValue(forKey: key)
            panelRevisionByKey.removeValue(forKey: key)
            pendingKicks.remove(key)
            if pendingKicks.isEmpty {
                scansRemainingForPendingKicks = 0
            }
            panelPortSnapshot.remove(keys: [key])
            panelPortOwnersByKey.removeValue(forKey: key)
            if ttyNames.isEmpty {
                burstGeneration &+= 1
                scheduledBurstTimers.values.forEach { $0.cancel() }
                scheduledBurstTimers.removeAll()
                burstActive = false
                coalesceTimer?.cancel()
                coalesceTimer = nil
            } else if !pendingKicks.isEmpty, !burstActive {
                startCoalesce()
            }
        }
    }

    @MainActor
    func freshReportedTTYName(workspaceId: UUID, panelId: UUID) -> String? {
        let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let ttyName = publicationState.registeredPanelTTYName(for: key),
              let sessionIdentity = ttySessionIdentityProvider(ttyName) else {
            return nil
        }
        return publicationState.currentPanelTTYName(for: key, sessionIdentity: sessionIdentity)
    }

    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)
            scansRemainingForPendingKicks = Self.minimumScansPerKick

            if !burstActive {
                startCoalesce()
            }
            // If a burst is active, its later scans pay down this count. A
            // follow-up burst starts when too few scans remained.
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

    /// Stops tracking an agent workspace and clears its published ports and owner evidence.
    @MainActor
    func unregisterAgentWorkspace(workspaceId: UUID) {
        _ = publicationState.invalidateAgentLifecycle(for: workspaceId)
        queue.async { [self] in
            agentRevisionByWorkspace.removeValue(forKey: workspaceId)
            _ = agentTrackingState.replaceRoots([], workspaceId: workspaceId)
            trackedAgentWorkspaces.remove(workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
            agentPortOwnersByWorkspace.removeValue(forKey: workspaceId)
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
        runBurst(index: 0, generation: burstGeneration)
    }

    private func runBurst(index: Int, burstStart: DispatchTime? = nil, generation: UInt64) {
        // Already on `queue`.
        guard generation == burstGeneration else { return }
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
        let timerID = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            guard generation == self.burstGeneration else { return }
            self.scheduledBurstTimers.removeValue(forKey: timerID)
            timer?.cancel()
            self.runScan(generation: generation)
            self.runBurst(index: index + 1, burstStart: start, generation: generation)
        }
        scheduledBurstTimers[timerID] = timer
        timer.resume()
    }

    // MARK: - Scan

    private func runScan(generation requestedGeneration: UInt64? = nil) {
        // Already on `queue`. Snapshot which panels to scan and their TTYs.
        // Capture the current burst generation at the scheduling boundary. A
        // default sentinel (such as zero) can accidentally accept a stale
        // completion when the first burst has been invalidated.
        let generation = requestedGeneration ?? burstGeneration
        // We scan all registered panels, not just pending ones, since ports can
        // appear/disappear on any panel.
        let panelSnapshot = ttyNames

        guard !panelSnapshot.isEmpty else {
            pendingKicks.removeAll()
            scansRemainingForPendingKicks = 0
            return
        }

        guard scanCoordination.beginPanelScan() else { return }

        if scansRemainingForPendingKicks > 0 {
            scansRemainingForPendingKicks -= 1
            if scansRemainingForPendingKicks == 0 {
                pendingKicks.removeAll()
            }
        }

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
                generation: generation,
                panelSnapshot: panelSnapshot,
                panelRevisions: panelRevisions,
                agentRootsByWorkspace: agentRootsByWorkspace,
                agentRevisions: agentRevisions,
                requestID: requestID
            )
        }
    }

    /// Completes one coalesced scan and assembles panel and agent ownership evidence.
    private func finishScan(
        generation: UInt64,
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
            let agentLsofEvidence = PortLsofScanResult(
                values: [:],
                globallyComplete: true,
                incompletePIDs: capturedAgentPIDs.incompletePIDs
            )
            let panelCompletenessByKey = Self.panelCompletenessByKey(
                panelTTYs: panelSnapshot,
                pidToTTY: pidToTTY,
                psCompleteness: psScan.completeness,
                lsofScan: panelLsofEvidence
            )
            queue.async { [weak self] in
                self?.completePanelScan(
                    generation: generation,
                    panelResults,
                    panelTTYs: panelSnapshot,
                    panelRevisions: panelRevisions,
                    workspaceIds: workspaceIds,
                    agentPortsByWorkspace: [:],
                    panelPortOwnersByKey: [:],
                    panelProcessIdentitiesByKey: [:],
                    agentPortOwnersByWorkspace: [:],
                    agentProcessIdentitiesByWorkspace: [:],
                    agentRevisions: agentRevisions,
                    panelCompletenessByKey: panelCompletenessByKey,
                    panelProcessScopeCompletenessByKey: panelCompletenessByKey,
                    agentCompletenessByWorkspace: agentCompletenessBeforeLsof,
                    agentProcessScopeCompletenessByWorkspace: agentCompletenessBeforeLsof,
                    panelLsofEvidence: panelLsofEvidence,
                    agentLsofEvidence: agentLsofEvidence,
                    inspectedPIDs: [],
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
        var panelPortOwnersByKey: [PanelKey: [Int: Set<AgentPIDProcessIdentity>]] = [:]
        let panelKeysByTTY = panelSnapshot.reduce(into: [String: [PanelKey]]()) { result, entry in
            result[entry.value, default: []].append(entry.key)
        }
        var panelProcessIdentitiesByKey: [PanelKey: Set<AgentPIDProcessIdentity>] = [:]
        for (pid, tty) in validPIDToTTY {
            guard let identity = capturedPanelPIDs.identitiesByPID[pid] else { continue }
            for key in panelKeysByTTY[tty] ?? [] {
                panelProcessIdentitiesByKey[key, default: []].insert(identity)
            }
        }
        for (pid, ports) in pidToPorts {
            guard let tty = validPIDToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
            guard let identity = capturedPanelPIDs.identitiesByPID[pid] else { continue }
            for key in panelKeysByTTY[tty] ?? [] {
                for port in ports {
                    panelPortOwnersByKey[key, default: [:]][port, default: []].insert(identity)
                }
            }
        }

        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        var agentPortOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]] = [:]
        var agentProcessIdentitiesByWorkspace: [UUID: Set<AgentPIDProcessIdentity>] = [:]
        for (pid, ownership) in agentOwnershipByPID {
            guard let identity = capturedAgentPIDs.identitiesByPID[pid] else { continue }
            for workspaceId in ownership {
                agentProcessIdentitiesByWorkspace[workspaceId, default: []].insert(identity)
            }
        }
        for (pid, ports) in pidToPorts {
            guard let ownership = agentOwnershipByPID[pid] else { continue }
            for workspaceId in ownership {
                agentPortsByWorkspace[workspaceId, default: []].formUnion(ports)
                guard let identity = capturedAgentPIDs.identitiesByPID[pid] else { continue }
                for port in ports {
                    agentPortOwnersByWorkspace[workspaceId, default: [:]][port, default: []]
                        .insert(identity)
                }
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
        let agentProcessScopeCompletenessByWorkspace = combineAgentCompleteness(
            agentCompletenessBeforeLsof,
            finalizedAgentPIDs.completenessByWorkspace,
            workspaceIds: workspaceIds
        )
        let agentCompletenessByWorkspace = combineAgentCompleteness(
            agentProcessScopeCompletenessByWorkspace,
            lsofAgentCompleteness,
            workspaceIds: workspaceIds
        )
        let panelProcessScopeEvidence = PortLsofScanResult(
            values: [:],
            globallyComplete: true,
            incompletePIDs: capturedPanelPIDs.incompletePIDs
                .union(revalidatedPanelPIDs.incompletePIDs)
        )
        let panelLsofEvidence = PortLsofScanResult(
            values: lsofScan.values,
            globallyComplete: lsofScan.globallyComplete,
            incompletePIDs: lsofScan.incompletePIDs
                .union(capturedPanelPIDs.incompletePIDs)
                .union(revalidatedPanelPIDs.incompletePIDs)
        )
        let panelProcessScopeCompletenessByKey = Self.panelCompletenessByKey(
            panelTTYs: panelSnapshot,
            pidToTTY: pidToTTY,
            psCompleteness: Self.combinedCompleteness(
                psScan.completeness,
                refreshedPanelProcessScan.completeness
            ),
            lsofScan: panelProcessScopeEvidence
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
                generation: generation,
                panelResults,
                panelTTYs: panelSnapshot,
                panelRevisions: panelRevisions,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsSnapshot,
                panelPortOwnersByKey: panelPortOwnersByKey,
                panelProcessIdentitiesByKey: panelProcessIdentitiesByKey,
                agentPortOwnersByWorkspace: agentPortOwnersByWorkspace,
                agentProcessIdentitiesByWorkspace: agentProcessIdentitiesByWorkspace,
                agentRevisions: agentRevisions,
                panelCompletenessByKey: panelCompletenessByKey,
                panelProcessScopeCompletenessByKey: panelProcessScopeCompletenessByKey,
                agentCompletenessByWorkspace: agentCompletenessByWorkspace,
                agentProcessScopeCompletenessByWorkspace: agentProcessScopeCompletenessByWorkspace,
                panelLsofEvidence: panelLsofEvidence,
                agentLsofEvidence: lsofScan,
                inspectedPIDs: allPids,
                requestID: requestID
            )
        }
    }

    /// Applies a completed panel scan on the scanner queue and starts any pending scan.
    func completePanelScan(
        generation: UInt64,
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        panelRevisions: [PanelKey: UInt64],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        panelPortOwnersByKey: [PanelKey: [Int: Set<AgentPIDProcessIdentity>]],
        panelProcessIdentitiesByKey: [PanelKey: Set<AgentPIDProcessIdentity>],
        agentPortOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]],
        agentProcessIdentitiesByWorkspace: [UUID: Set<AgentPIDProcessIdentity>],
        agentRevisions: [UUID: UInt64],
        panelCompletenessByKey: [PanelKey: PortScanCompleteness],
        panelProcessScopeCompletenessByKey: [PanelKey: PortScanCompleteness],
        agentCompletenessByWorkspace: [UUID: PortScanCompleteness],
        agentProcessScopeCompletenessByWorkspace: [UUID: PortScanCompleteness],
        panelLsofEvidence: PortLsofScanResult,
        agentLsofEvidence: PortLsofScanResult?,
        inspectedPIDs: Set<Int>,
        requestID: UInt64
    ) {
        let hasPendingScan = scanCoordination.finishPanelScan()
        let isCurrentGeneration = generation == burstGeneration
        deliverResults(
            panelResults,
            panelTTYs: panelTTYs,
            panelRevisions: panelRevisions,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            panelPortOwnersByKey: panelPortOwnersByKey,
            panelProcessIdentitiesByKey: panelProcessIdentitiesByKey,
            agentPortOwnersByWorkspace: agentPortOwnersByWorkspace,
            agentProcessIdentitiesByWorkspace: agentProcessIdentitiesByWorkspace,
            agentRevisions: agentRevisions,
            panelCompletenessByKey: panelCompletenessByKey,
            panelProcessScopeCompletenessByKey: panelProcessScopeCompletenessByKey,
            agentCompletenessByWorkspace: agentCompletenessByWorkspace,
            agentProcessScopeCompletenessByWorkspace: agentProcessScopeCompletenessByWorkspace,
            panelLsofEvidence: panelLsofEvidence,
            agentLsofEvidence: agentLsofEvidence,
            inspectedPIDs: inspectedPIDs,
            requestID: requestID,
            applyPanelResults: isCurrentGeneration
        )
        if hasPendingScan {
            runScan(generation: burstGeneration)
        }
    }

    /// Updates agent tracking state while already confined to the scanner queue.
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
            agentPortOwnersByWorkspace.removeValue(forKey: workspaceId)
            scanCoordination.removeAgentWorkspaces([workspaceId])
            updateAgentScanTimerLocked()
            forceAgentResultWorkspaces.insert(workspaceId)
            deliverAgentResults(
                workspaceIds: [workspaceId],
                agentPortsByWorkspace: [:],
                observedOwnersByWorkspace: [:],
                currentProcessIdentitiesByWorkspace: [:],
                agentRevisions: [workspaceId: revision],
                completenessByWorkspace: [workspaceId: .complete],
                processScopeCompletenessByWorkspace: [workspaceId: .complete],
                lsofScan: nil,
                inspectedPIDs: [],
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
    /// Scans an agent process tree, resolves listener owners, and queues its result.
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
                let lsofEvidence = PortLsofScanResult(
                    values: [:],
                    globallyComplete: true,
                    incompletePIDs: capturedAgentPIDs.incompletePIDs
                )
                self.queue.async { [weak self] in
                    self?.completeAgentScan(
                        request,
                        agentPortsByWorkspace: [:],
                        observedOwnersByWorkspace: [:],
                        currentProcessIdentitiesByWorkspace: [:],
                        completenessByWorkspace: agentCompletenessBeforeLsof,
                        processScopeCompletenessByWorkspace: agentCompletenessBeforeLsof,
                        lsofScan: lsofEvidence,
                        inspectedPIDs: []
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
            var agentPortOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]] = [:]
            var agentProcessIdentitiesByWorkspace: [UUID: Set<AgentPIDProcessIdentity>] = [:]
            for (pid, ownership) in agentOwnershipByPID {
                guard let identity = capturedAgentPIDs.identitiesByPID[pid] else { continue }
                for workspaceId in ownership {
                    agentProcessIdentitiesByWorkspace[workspaceId, default: []].insert(identity)
                }
            }
            for (pid, ports) in pidToPorts {
                guard let ownership = agentOwnershipByPID[pid] else { continue }
                for targetWorkspaceId in ownership {
                    agentPortsByWorkspace[targetWorkspaceId, default: []].formUnion(ports)
                    guard let identity = capturedAgentPIDs.identitiesByPID[pid] else { continue }
                    for port in ports {
                        agentPortOwnersByWorkspace[targetWorkspaceId, default: [:]][port, default: []]
                            .insert(identity)
                    }
                }
            }
            let agentPortsSnapshot = agentPortsByWorkspace
            let agentPortOwnersSnapshot = agentPortOwnersByWorkspace
            let lsofCompletenessByWorkspace = self.agentLsofCompleteness(
                ownershipByPID: agentOwnershipByPID,
                lsofScan: lsofScan,
                workspaceIds: request.workspaceIds
            )
            let processScopeCompletenessByWorkspace = self.combineAgentCompleteness(
                agentCompletenessBeforeLsof,
                finalizedAgentPIDs.completenessByWorkspace,
                workspaceIds: request.workspaceIds
            )
            let completenessByWorkspace = self.combineAgentCompleteness(
                processScopeCompletenessByWorkspace,
                lsofCompletenessByWorkspace,
                workspaceIds: request.workspaceIds
            )

            self.queue.async { [weak self] in
                self?.completeAgentScan(
                    request,
                    agentPortsByWorkspace: agentPortsSnapshot,
                    observedOwnersByWorkspace: agentPortOwnersSnapshot,
                    currentProcessIdentitiesByWorkspace: agentProcessIdentitiesByWorkspace,
                    completenessByWorkspace: completenessByWorkspace,
                    processScopeCompletenessByWorkspace: processScopeCompletenessByWorkspace,
                    lsofScan: lsofScan,
                    inspectedPIDs: Set(capturedAgentPIDs.ownershipByPID.keys)
                )
            }
        }
    }

    /// Applies an agent scan result and starts the next queued agent request if needed.
    private func completeAgentScan(
        _ request: AgentPortScanRequest,
        agentPortsByWorkspace: [UUID: Set<Int>],
        observedOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]],
        currentProcessIdentitiesByWorkspace: [UUID: Set<AgentPIDProcessIdentity>],
        completenessByWorkspace: [UUID: PortScanCompleteness],
        processScopeCompletenessByWorkspace: [UUID: PortScanCompleteness],
        lsofScan: PortLsofScanResult?,
        inspectedPIDs: Set<Int>
    ) {
        let pendingRequest = scanCoordination.finishAgentScan()
        deliverAgentResults(
            workspaceIds: request.workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            observedOwnersByWorkspace: observedOwnersByWorkspace,
            currentProcessIdentitiesByWorkspace: currentProcessIdentitiesByWorkspace,
            agentRevisions: request.agentRevisions,
            completenessByWorkspace: completenessByWorkspace,
            processScopeCompletenessByWorkspace: processScopeCompletenessByWorkspace,
            lsofScan: lsofScan,
            inspectedPIDs: inspectedPIDs,
            requestID: request.requestID
        )
        if let pendingRequest {
            startAgentScan(pendingRequest)
        }
    }

    /// Reconciles panel and agent results through their shared publication paths.
    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        panelRevisions: [PanelKey: UInt64],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        panelPortOwnersByKey: [PanelKey: [Int: Set<AgentPIDProcessIdentity>]],
        panelProcessIdentitiesByKey: [PanelKey: Set<AgentPIDProcessIdentity>],
        agentPortOwnersByWorkspace: [UUID: [Int: Set<AgentPIDProcessIdentity>]],
        agentProcessIdentitiesByWorkspace: [UUID: Set<AgentPIDProcessIdentity>],
        agentRevisions: [UUID: UInt64],
        panelCompletenessByKey: [PanelKey: PortScanCompleteness],
        panelProcessScopeCompletenessByKey: [PanelKey: PortScanCompleteness],
        agentCompletenessByWorkspace: [UUID: PortScanCompleteness],
        agentProcessScopeCompletenessByWorkspace: [UUID: PortScanCompleteness],
        panelLsofEvidence: PortLsofScanResult,
        agentLsofEvidence: PortLsofScanResult?,
        inspectedPIDs: Set<Int>,
        requestID: UInt64,
        applyPanelResults: Bool
    ) {
        if applyPanelResults, scanCoordination.shouldApplyPanelResult(requestID: requestID) {
            let scannedPorts = Dictionary(uniqueKeysWithValues: panelResults.filter { key, _ in
                ttyNames[key] == panelTTYs[key]
                    && panelRevisionByKey[key] == panelRevisions[key]
            })
            let trackedKeys = Set(ttyNames.keys)
            let panelCompletenessByPort = missingPortCompletenessByKey(
                previousOwnersByKey: self.panelPortOwnersByKey,
                observedOwnersByKey: panelPortOwnersByKey,
                currentProcessIdentitiesByKey: panelProcessIdentitiesByKey,
                processScopeCompletenessByKey: panelProcessScopeCompletenessByKey,
                scannedKeys: Set(scannedPorts.keys),
                lsofScan: panelLsofEvidence,
                inspectedPIDs: inspectedPIDs
            )
            let stableSnapshot = panelPortSnapshot.reconcile(
                scannedPorts: scannedPorts,
                scannedKeys: Set(scannedPorts.keys),
                trackedKeys: trackedKeys,
                completenessByKey: panelCompletenessByKey,
                completenessByPort: panelCompletenessByPort
            )
            Self.updatePortOwners(
                &self.panelPortOwnersByKey,
                observedOwnersByKey: panelPortOwnersByKey,
                scannedKeys: Set(scannedPorts.keys),
                trackedKeys: trackedKeys,
                publishedSnapshot: stableSnapshot
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
            observedOwnersByWorkspace: agentPortOwnersByWorkspace,
            currentProcessIdentitiesByWorkspace: agentProcessIdentitiesByWorkspace,
            agentRevisions: agentRevisions,
            completenessByWorkspace: agentCompletenessByWorkspace,
            processScopeCompletenessByWorkspace: agentProcessScopeCompletenessByWorkspace,
            lsofScan: agentLsofEvidence,
            inspectedPIDs: inspectedPIDs,
            requestID: requestID
        )
    }

    private func agentRevisionSnapshot(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
            partial[workspaceId] = agentRevisionByWorkspace[workspaceId, default: 0]
        }
    }

}
