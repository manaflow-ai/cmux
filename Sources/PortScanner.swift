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
        let psScan = ttyList.isEmpty
            ? (values: [Int: String](), completeness: PortScanCompleteness.complete)
            : runPS(ttyList: ttyList)
        let agentProcessScan = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)
        let pidToTTY = psScan.values
        let agentPidToWorkspaces = agentProcessScan.values

        let allPids = Set(pidToTTY.keys).union(agentPidToWorkspaces.keys)
        guard !allPids.isEmpty else {
            let panelResults = panelSnapshot.map { ($0.key, [Int]()) }
            deliverResults(
                panelResults,
                panelTTYs: panelSnapshot,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions,
                panelCompleteness: psScan.completeness,
                agentCompleteness: agentProcessScan.completeness
            )
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidsCsv = allPids.sorted().map(String.init).joined(separator: ",")
        let lsofScan = runLsof(pidsCsv: pidsCsv)
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

        deliverResults(
            results,
            panelTTYs: panelSnapshot,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            panelCompleteness: Self.combinedCompleteness(psScan.completeness, lsofScan.completeness),
            agentCompleteness: Self.combinedCompleteness(agentProcessScan.completeness, lsofScan.completeness)
        )
    }

    private func refreshAgentPortsLocked(workspaceId: UUID, agentPIDs: Set<Int>) {
        let agentRevision = nextAgentRevision(for: workspaceId)
        let normalizedPIDs = Set(agentPIDs.filter { $0 > 0 })
        if normalizedPIDs.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
            agentPortSnapshot.remove(keys: [workspaceId])
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
        guard let agentPIDsProvider else {
            trackedAgentWorkspaces.removeAll()
            agentPortSnapshot.reset()
            updateAgentScanTimerLocked()
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions,
                completeness: .complete
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
            agentPortSnapshot.remove(keys: inactiveWorkspaceIds)
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

        let agentProcessScan = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)
        let agentPidToWorkspaces = agentProcessScan.values
        guard !agentPidToWorkspaces.isEmpty else {
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions,
                completeness: agentProcessScan.completeness
            )
            return
        }

        let pidsCsv = agentPidToWorkspaces.keys.sorted().map(String.init).joined(separator: ",")
        let lsofScan = runLsof(pidsCsv: pidsCsv)
        let pidToPorts = lsofScan.values
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
            agentRevisions: agentRevisions,
            completeness: Self.combinedCompleteness(agentProcessScan.completeness, lsofScan.completeness)
        )
    }

    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        panelTTYs: [PanelKey: String],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        panelCompleteness: PortScanCompleteness,
        agentCompleteness: PortScanCompleteness
    ) {
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
        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            completeness: agentCompleteness
        )
    }

    private func deliverAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        completeness: PortScanCompleteness
    ) {
        guard let agentCallback = onAgentPortsUpdated else { return }
        Task { [weak self] in
            guard let self else { return }
            let validatedResults = await self.validatedAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsByWorkspace,
                agentRevisions: agentRevisions,
                completeness: completeness
            )
            guard !validatedResults.isEmpty else { return }
            let appliedResults = await MainActor.run {
                validatedResults.filter { result in
                    agentCallback(result.workspaceId, result.ports)
                }
            }
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
                    guard agentRevisionByWorkspace[workspaceId, default: 0] == revision else { continue }
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
        agentRevisions: [UUID: UInt64],
        completeness: PortScanCompleteness
    ) async -> [(workspaceId: UUID, ports: [Int], revision: UInt64)] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var results: [(workspaceId: UUID, ports: [Int], revision: UInt64)] = []
                let validWorkspaceIds = Set(workspaceIds.filter { workspaceId in
                    agentRevisionByWorkspace[workspaceId, default: 0] == agentRevisions[workspaceId, default: 0]
                })
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
                    results.append((workspaceId: workspaceId, ports: ports, revision: expectedRevision))
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
