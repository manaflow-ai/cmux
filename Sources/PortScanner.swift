import CmuxFoundation
import Foundation
import os

/// Batched port scanner that replaces per-shell process and socket scanning.
///
/// Each shell sends a lightweight `report_tty` + `ports_kick` over the socket.
/// PortScanner coalesces kicks across all panels, then combines one shared
/// process snapshot with a bounded libproc socket scan covering every panel.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds panel to `pendingKicks` set
/// 2. If no burst is active, starts a 200ms coalesce timer
/// 3. Coalesce fires → snapshots pending set → starts 4 bounded refresh probes
/// 4. New kicks during burst merge into the active burst
/// 5. After last scan, if new kicks arrived, start a new coalesce cycle
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    /// Serializes generation advances with the corresponding main-actor UI
    /// mutation. A worker-queue validation alone is insufficient because a
    /// newer scan can advance while the accepted result is queued for MainActor.
    final class ResultGenerationGate: @unchecked Sendable {
        private struct State {
            var panelRevision: UInt64 = 0
            var agentRevisionByWorkspace: [UUID: UInt64] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func advancePanel(to revision: UInt64) {
            state.withLock { state in
                state.panelRevision = revision
            }
        }

        func advanceAgent(workspaceId: UUID, to revision: UInt64) {
            state.withLock { state in
                state.agentRevisionByWorkspace[workspaceId] = revision
            }
        }

        /// The callback runs while generation ownership is held, so an advance
        /// cannot interleave between the final check and the UI mutation.
        @MainActor
        func applyPanel<Result>(
            ifCurrent revision: UInt64,
            _ callback: () -> Result
        ) -> Result? {
            state.withLock { state in
                guard PortScanner.acceptsResult(
                    currentRevision: state.panelRevision,
                    expectedRevision: revision,
                    staleMetric: .portPanelRevision
                ) else { return nil }
                return callback()
            }
        }

        /// The callback runs while generation ownership is held, so an advance
        /// cannot interleave between the final check and the UI mutation.
        @MainActor
        func applyAgent<Result>(
            workspaceId: UUID,
            ifCurrent revision: UInt64,
            _ callback: () -> Result
        ) -> Result? {
            state.withLock { state in
                guard PortScanner.acceptsResult(
                    currentRevision: state.agentRevisionByWorkspace[workspaceId, default: 0],
                    expectedRevision: revision,
                    staleMetric: .portAgentRevision
                ) else { return nil }
                return callback()
            }
        }
    }

    /// Callback delivers `(workspaceId, panelId, ports)` on the main actor.
    var onPortsUpdated: (@MainActor (_ workspaceId: UUID, _ panelId: UUID, _ ports: [Int]) -> Void)?
    /// Callback delivers workspace-scoped ports owned by tracked agents.
    var onAgentPortsUpdated: (@MainActor (_ workspaceId: UUID, _ ports: [Int]) -> Bool)?
    /// Provider returns tracked agent root PIDs for the given workspaces.
    var agentPIDsProvider: (@MainActor (_ workspaceIds: Set<UUID>) -> [UUID: Set<Int>])?

    // MARK: - State (all guarded by `queue`)

    private let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)
    private let portScanSnapshotStore = PortScanSnapshotStore()
    private let resultGenerationGate = ResultGenerationGate()

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
    // Preexec fires before a server binds. Four probes preserve the original
    // ten-second discovery window without launching six heavyweight scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 4, 10]
    private static let agentRescanInterval: TimeInterval = 2
    private static let panelPortScanMaximumAge: TimeInterval = 0.5
    private static let agentPortScanMaximumAge = agentRescanInterval

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
            advancePanelRevision()
        }
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            let removedTTY = ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
            if removedTTY != nil {
                advancePanelRevision()
            }
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
        let scanRevision = advancePanelRevision()
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
            let pidToPorts = await self.portScanSnapshotStore.snapshot(
                pids: allPIDs,
                maximumAge: Self.panelPortScanMaximumAge
            )
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
                    panelRevision: scanRevision,
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
            let pidToPorts = await self.portScanSnapshotStore.snapshot(
                pids: Set(agentPidToWorkspaces.keys),
                maximumAge: Self.agentPortScanMaximumAge
            )
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
        panelRevision: UInt64,
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        let panelCallback = onPortsUpdated
        if let panelCallback {
            Task { @MainActor [resultGenerationGate] in
                resultGenerationGate.applyPanel(ifCurrent: panelRevision) {
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
                    self.resultGenerationGate.applyAgent(
                        workspaceId: result.workspaceId,
                        ifCurrent: result.revision
                    ) {
                        agentCallback(result.workspaceId, result.ports)
                    } ?? false
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
        resultGenerationGate.advanceAgent(workspaceId: workspaceId, to: nextRevision)
        return nextRevision
    }

    @discardableResult
    private func advancePanelRevision() -> UInt64 {
        panelScanRevision &+= 1
        resultGenerationGate.advancePanel(to: panelScanRevision)
        return panelScanRevision
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

    static func scanListeningPorts(pids: Set<Int>) -> [Int: Set<Int>] {
        guard !pids.isEmpty else { return [:] }
        var result: [Int: Set<Int>] = [:]
        for pid in pids.sorted() where pid > 0 {
            let rawPID = pid_t(pid)
            let requiredBytes = proc_pidinfo(rawPID, PROC_PIDLISTFDS, 0, nil, 0)
            guard requiredBytes > 0 else { continue }

            // Leave spare entries for descriptors opened between sizing and
            // the second syscall. A truncated list is refreshed on the next
            // bounded scan and never blocks another consumer.
            let requiredCount = Int(requiredBytes) / MemoryLayout<proc_fdinfo>.stride
            let capacity = max(1, requiredCount + 16)
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bufferBytes = Int32(capacity * MemoryLayout<proc_fdinfo>.stride)
            let usedBytes = proc_pidinfo(
                rawPID,
                PROC_PIDLISTFDS,
                0,
                &descriptors,
                bufferBytes
            )
            guard usedBytes > 0 else { continue }

            let descriptorCount = min(
                descriptors.count,
                Int(usedBytes) / MemoryLayout<proc_fdinfo>.stride
            )
            for descriptor in descriptors.prefix(descriptorCount)
                where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socketInfo = socket_fdinfo()
                let infoBytes = proc_pidfdinfo(
                    rawPID,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
                guard infoBytes == MemoryLayout<socket_fdinfo>.size,
                      let port = listeningTCPPort(from: socketInfo) else {
                    continue
                }
                result[pid, default: []].insert(port)
            }
        }
        return result
    }

    static func listeningTCPPort(from socketInfo: socket_fdinfo) -> Int? {
        guard socketInfo.psi.soi_kind == SOCKINFO_TCP,
              socketInfo.psi.soi_protocol == IPPROTO_TCP,
              socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else {
            return nil
        }
        let networkPort = UInt16(
            truncatingIfNeeded: socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
        )
        let port = Int(UInt16(bigEndian: networkPort))
        return port > 0 ? port : nil
    }
}
