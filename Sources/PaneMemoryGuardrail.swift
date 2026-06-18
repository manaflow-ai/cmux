import Darwin
import Foundation
import Observation

// MARK: - Value types

/// Stable identity of a single pane (workspace + panel) for guardrail tracking.
struct PaneMemoryPaneKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

/// Main-actor snapshot of one live pane gathered before an off-main memory scan.
/// `ttyName` / `foregroundPID` come from libghostty (see
/// `TerminalSurface.controllingTTYName()` / `foregroundProcessID()`).
struct PaneMemoryDescriptor: Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let workspaceTitle: String
    let paneTitle: String
    let ttyName: String?
    let foregroundPID: Int?

    var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

/// Result of summing a pane's process-tree memory off the main thread.
struct PaneMemorySample: Sendable {
    let descriptor: PaneMemoryDescriptor
    /// Physical-footprint bytes summed across every process sharing the pane's
    /// controlling tty. This is what macOS aggregates for "out of application
    /// memory", so it is the signal the threshold is compared against.
    let memoryBytes: Int64
    /// Resident bytes summed across the same process set (informational).
    let residentBytes: Int64
    /// Process-group ids that contribute enough memory to clear this pane's warning.
    let memoryPressureProcessGroupIDs: [Int]
    let foregroundCommand: String?

    var key: PaneMemoryPaneKey { descriptor.key }

    var warning: PaneMemoryWarning {
        PaneMemoryWarning(
            workspaceId: descriptor.workspaceId,
            panelId: descriptor.panelId,
            workspaceTitle: descriptor.workspaceTitle,
            paneTitle: descriptor.paneTitle,
            memoryBytes: memoryBytes,
            foregroundCommand: foregroundCommand
        )
    }
}

/// The content surfaced in the dismissible warning banner.
struct PaneMemoryWarning: Equatable, Identifiable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let workspaceTitle: String
    let paneTitle: String
    let memoryBytes: Int64
    let foregroundCommand: String?

    var id: UUID { panelId }
    var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

// MARK: - Pure edge-trigger engine (unit-tested in isolation)

/// Stateless-per-call decision core for the guardrail. Owns only the
/// warned/dismissed sets so the threshold crossing logic (edge-trigger +
/// hysteresis) is testable without timers, ghostty, or libproc.
struct PaneMemoryGuardrailEngine {
    /// Banner clears once a warned pane drops below `clearFraction × threshold`.
    /// The gap between warn and clear is hysteresis so a pane hovering at the
    /// threshold does not flap the badge/banner every tick.
    static let clearFraction = 0.8

    private(set) var warnedPanes: Set<PaneMemoryPaneKey> = []
    private(set) var dismissedPanes: Set<PaneMemoryPaneKey> = []

    var warnedWorkspaceIds: Set<UUID> { Set(warnedPanes.map(\.workspaceId)) }

    struct Output: Equatable {
        /// Panes that crossed the threshold this tick and whose banners have not
        /// been dismissed — present each once (edge-trigger).
        var bannersToPresent: [PaneMemoryWarning]
        /// Workspaces that currently own at least one warned pane (badge set).
        var warnedWorkspaceIds: Set<UUID>
        /// Panes currently in warned state.
        var warnedPaneKeys: Set<PaneMemoryPaneKey>
        /// Panes that dropped below the clear level this tick.
        var clearedPanes: Set<PaneMemoryPaneKey>

        var bannerToPresent: PaneMemoryWarning? { bannersToPresent.first }
    }

    mutating func ingest(samples: [PaneMemorySample], thresholdBytes: Int64) -> Output {
        let clearBytes = Int64(Double(thresholdBytes) * Self.clearFraction)
        let liveKeys = Set(samples.map(\.key))
        // Forget panes that no longer exist so closed panes never keep a badge.
        warnedPanes.formIntersection(liveKeys)
        dismissedPanes.formIntersection(liveKeys)

        var bannersToPresent: [PaneMemoryWarning] = []
        var clearedPanes: Set<PaneMemoryPaneKey> = []

        for sample in samples {
            let key = sample.key
            if sample.memoryBytes >= thresholdBytes {
                if warnedPanes.insert(key).inserted, !dismissedPanes.contains(key) {
                    // First crossing (or first since it cleared) — fire once.
                    bannersToPresent.append(sample.warning)
                }
            } else if sample.memoryBytes < clearBytes {
                warnedPanes.remove(key)
                dismissedPanes.remove(key)
                clearedPanes.insert(key)
            }
            // In the hysteresis band [clearBytes, thresholdBytes): keep state.
        }

        return Output(
            bannersToPresent: bannersToPresent,
            warnedWorkspaceIds: warnedWorkspaceIds,
            warnedPaneKeys: warnedPanes,
            clearedPanes: clearedPanes
        )
    }

    /// User dismissed the banner for `key`; suppress re-firing while it stays
    /// high. The badge persists until the pane drops below the clear level.
    mutating func dismiss(_ key: PaneMemoryPaneKey) {
        dismissedPanes.insert(key)
    }

    /// The pane's runaway tree was killed; drop its warned/dismissed state so a
    /// future leak re-warns cleanly.
    mutating func acknowledgeHandled(_ key: PaneMemoryPaneKey) {
        warnedPanes.remove(key)
        dismissedPanes.remove(key)
    }

    mutating func reset() {
        warnedPanes.removeAll()
        dismissedPanes.removeAll()
    }
}

// MARK: - Process-group killer

enum PaneMemoryProcessKiller {
    /// SIGTERM the pane's high-memory process group(s) now, then SIGKILL after a
    /// short grace. Negative pid targets the whole process group, so the runaway
    /// job and its descendants die without signaling unrelated groups in the
    /// same pane. ESRCH on an already-dead group is harmless.
    static func terminate(processGroupIDs: [Int], graceSeconds: TimeInterval = 3) -> Task<Void, Never>? {
        let pgids = processGroupIDs.filter { $0 > 1 }
        guard !pgids.isEmpty else { return nil }
        for pgid in pgids {
            _ = kill(pid_t(-pgid), SIGTERM)
        }
        let delayNanoseconds = UInt64(max(0, graceSeconds) * 1_000_000_000)
        return Task.detached(priority: .userInitiated) { [pgids] in
            // Bounded SIGTERM grace period before escalation; cancellation suppresses SIGKILL.
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            for pgid in pgids {
                _ = kill(pid_t(-pgid), SIGKILL)
            }
        }
    }
}

// MARK: - Monitor

/// One instance owns the background poll timer, scans every live pane each tick,
/// attributes process-tree memory by controlling tty, and drives the per-pane
/// warning badge + dismissible banner. The heavy libproc scan runs off the main
/// thread; only the small state updates touch `@MainActor`.
@MainActor
@Observable
final class PaneMemoryGuardrail {
    static let shared = PaneMemoryGuardrail()

    enum DefaultsKeys {
        static let enabled = "terminal.runawayMemoryGuardrail.enabled"
        static let thresholdGB = "terminal.runawayMemoryGuardrail.thresholdGB"
    }

    private static let pollInterval: TimeInterval = 4
    private static let defaultThresholdGB: Double = 8
    private static let minThresholdGB: Double = 1

    /// The banner content for the most recent un-dismissed crossing, or nil.
    private(set) var activeBanner: PaneMemoryWarning?

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    @ObservationIgnored
    var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Pushes the set of workspaces that should show a warning badge.
    @ObservationIgnored
    var onWarnedWorkspacesChanged: (@MainActor (Set<UUID>) -> Void)?
    /// Fallback when a pane has no high-memory process group to signal: close it.
    @ObservationIgnored
    var onRequestClosePane: (@MainActor (_ workspaceId: UUID, _ panelId: UUID) -> Void)?

    @ObservationIgnored
    private var engine = PaneMemoryGuardrailEngine()
    @ObservationIgnored
    private let timerQueue = DispatchQueue(label: "com.cmux.pane-memory-guardrail", qos: .utility)
    @ObservationIgnored
    private var timer: DispatchSourceTimer?
    @ObservationIgnored
    private var isScanning = false
    @ObservationIgnored
    private var scanApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastSamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    @ObservationIgnored
    private var lastWarnedWorkspaceIds: Set<UUID> = []
    @ObservationIgnored
    private var pendingBanners: [PaneMemoryWarning] = []
    @ObservationIgnored
    private var pendingKillTasksByKey: [PaneMemoryPaneKey: (id: UUID, task: Task<Void, Never>)] = [:]

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.resume()
    }

    // MARK: Settings

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.enabled) as? Bool ?? true
    }

    private func thresholdBytes() -> Int64 {
        let configured = UserDefaults.standard.object(forKey: DefaultsKeys.thresholdGB) as? Double
            ?? Self.defaultThresholdGB
        let gb = max(Self.minThresholdGB, configured)
        return Int64(gb * 1024 * 1024 * 1024)
    }

    // MARK: Tick

    private func tick() {
        guard isEnabled else {
            clearAll()
            return
        }
        guard !isScanning, let paneProvider else { return }
        let descriptors = paneProvider()
        guard !descriptors.isEmpty else {
            clearAll()
            return
        }
        let thresholdBytes = thresholdBytes()
        isScanning = true
        let sampleTask = Task.detached(priority: .utility) {
            Self.computeSamples(descriptors: descriptors, thresholdBytes: thresholdBytes)
        }
        scanApplyTask = Task { @MainActor [weak self] in
            let samples = await sampleTask.value
            guard !Task.isCancelled else { return }
            self?.applySamples(samples, thresholdBytes: thresholdBytes)
        }
    }

    /// Off-main: capture one process snapshot and attribute memory per pane by
    /// controlling-tty device (the snapshot already indexes pids by tty dev).
    nonisolated static func computeSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64
    ) -> [PaneMemorySample] {
        let snapshot = CmuxTopProcessSnapshot.capture()
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            guard let ttyName = descriptor.ttyName else {
                return PaneMemorySample(
                    descriptor: descriptor,
                    memoryBytes: 0,
                    residentBytes: 0,
                    memoryPressureProcessGroupIDs: [],
                    foregroundCommand: nil
                )
            }
            let pids = snapshot.pids(forTTYName: ttyName)
            let summary = snapshot.summary(for: pids)
            let pgids = memoryPressureProcessGroupIDs(
                in: snapshot,
                pids: pids,
                clearBytes: clearBytes
            )
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                memoryPressureProcessGroupIDs: pgids,
                foregroundCommand: foregroundCommand
            )
        }
    }

    nonisolated static func memoryPressureProcessGroupIDs(
        in snapshot: CmuxTopProcessSnapshot,
        pids: Set<Int>,
        clearBytes: Int64
    ) -> [Int] {
        var totalBytes: Int64 = 0
        var bytesByProcessGroup: [Int: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid) else { continue }
            let memoryBytes = max(0, process.memoryBytes)
            totalBytes = totalBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : totalBytes + memoryBytes
            guard let processGroupID = process.processGroupID, processGroupID > 1 else { continue }
            let current = bytesByProcessGroup[processGroupID] ?? 0
            bytesByProcessGroup[processGroupID] = current.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : current + memoryBytes
        }

        guard totalBytes > clearBytes else { return [] }
        var selectedBytes: Int64 = 0
        var selectedProcessGroups: [Int] = []
        for (processGroupID, memoryBytes) in bytesByProcessGroup.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }) where memoryBytes > 0 {
            selectedProcessGroups.append(processGroupID)
            selectedBytes = selectedBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : selectedBytes + memoryBytes
            if totalBytes - selectedBytes < clearBytes { break }
        }
        return selectedProcessGroups.sorted()
    }

    private func applySamples(_ samples: [PaneMemorySample], thresholdBytes: Int64) {
        isScanning = false
        scanApplyTask = nil
        lastSamplesByKey = Dictionary(samples.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })

        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        cmuxDebugLog(
            "paneMemGuard.scan panes=\(samples.count) maxMB=\(maxBytes / 1_048_576) " +
            "thresholdMB=\(thresholdBytes / 1_048_576) warned=\(output.warnedWorkspaceIds.count) " +
            "fired=\(output.bannerToPresent != nil ? 1 : 0)"
        )
#endif

        enqueuePendingBanners(output.bannersToPresent)
        pendingBanners.removeAll { !output.warnedPaneKeys.contains($0.key) }

        // Banner lifecycle.
        if let active = activeBanner {
            let activeKey = active.key
            if output.clearedPanes.contains(activeKey) || lastSamplesByKey[activeKey] == nil {
                activeBanner = nil
            } else if let refreshed = lastSamplesByKey[activeKey], refreshed.memoryBytes >= thresholdBytes {
                // Keep the on-screen memory figure current while it stays high.
                let refreshedWarning = refreshed.warning
                if refreshedWarning != active {
                    activeBanner = refreshedWarning
                }
            }
        }
        presentNextPendingBannerIfNeeded()

        if output.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = output.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(output.warnedWorkspaceIds)
        }
    }

    // MARK: Banner actions

    func dismissActiveBanner() {
        guard let active = activeBanner else { return }
        engine.dismiss(active.key)
        pendingBanners.removeAll { $0.key == active.key }
        activeBanner = nil
        presentNextPendingBannerIfNeeded()
    }

    func killActivePaneProcess() { if let active = activeBanner { killPaneProcess(for: active) } }

    func killPaneProcess(for warning: PaneMemoryWarning) {
        let key = warning.key
        let descriptor = paneProvider?().first { $0.key == key }
        engine.acknowledgeHandled(key)
        pendingBanners.removeAll { $0.key == key }
        if activeBanner?.key == key {
            activeBanner = nil
        }
        if engine.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = engine.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(engine.warnedWorkspaceIds)
        }
        guard let descriptor else {
            presentNextPendingBannerIfNeeded()
            return
        }
        let thresholdBytes = thresholdBytes()
        let sampleTask = Task.detached(priority: .userInitiated) {
            Self.computeSamples(descriptors: [descriptor], thresholdBytes: thresholdBytes).first
        }
        presentNextPendingBannerIfNeeded()
        Task { @MainActor [weak self] in
            let sample = await sampleTask.value
            self?.finishKillActivePaneProcess(
                key: key,
                warning: warning,
                sample: sample,
                thresholdBytes: thresholdBytes
            )
        }
    }

    private func finishKillActivePaneProcess(
        key: PaneMemoryPaneKey,
        warning: PaneMemoryWarning,
        sample: PaneMemorySample?,
        thresholdBytes: Int64
    ) {
        guard let sample, sample.memoryBytes >= thresholdBytes else { return }
        let pgids = sample.memoryPressureProcessGroupIDs.filter { $0 > 1 }
        if pgids.isEmpty {
            onRequestClosePane?(warning.workspaceId, warning.panelId)
            return
        }
        pendingKillTasksByKey[key]?.task.cancel()
        guard let task = PaneMemoryProcessKiller.terminate(processGroupIDs: pgids) else { return }
        let id = UUID()
        pendingKillTasksByKey[key] = (id: id, task: task)
        Task { @MainActor [weak self] in
            await task.value
            if self?.pendingKillTasksByKey[key]?.id == id {
                self?.pendingKillTasksByKey[key] = nil
            }
        }
    }

    private func enqueuePendingBanners(_ warnings: [PaneMemoryWarning]) {
        guard !warnings.isEmpty else { return }
        let activeKey = activeBanner?.key
        var queuedKeys = Set(pendingBanners.map(\.key))
        for warning in warnings {
            guard warning.key != activeKey, queuedKeys.insert(warning.key).inserted else {
                continue
            }
            pendingBanners.append(warning)
        }
    }

    private func presentNextPendingBannerIfNeeded() {
        guard activeBanner == nil else { return }
        while !pendingBanners.isEmpty {
            let next = pendingBanners.removeFirst()
            guard let refreshed = lastSamplesByKey[next.key] else { continue }
            activeBanner = refreshed.warning
            return
        }
    }

    // MARK: Clearing

    private func clearAll() {
        engine.reset()
        isScanning = false
        scanApplyTask?.cancel()
        scanApplyTask = nil
        if activeBanner != nil { activeBanner = nil }
        pendingBanners.removeAll()
        lastSamplesByKey.removeAll()
        if !lastWarnedWorkspaceIds.isEmpty {
            lastWarnedWorkspaceIds = []
            onWarnedWorkspacesChanged?([])
        }
    }
}
