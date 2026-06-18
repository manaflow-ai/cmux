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
    /// Foreground process-group ids under the pane's tty, used as the kill target.
    let foregroundProcessGroupIDs: [Int]
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
        /// A pane that crossed the threshold this tick and whose banner has not
        /// been dismissed — present it once (edge-trigger).
        var bannerToPresent: PaneMemoryWarning?
        /// Workspaces that currently own at least one warned pane (badge set).
        var warnedWorkspaceIds: Set<UUID>
        /// Panes that dropped below the clear level this tick.
        var clearedPanes: Set<PaneMemoryPaneKey>
    }

    mutating func ingest(samples: [PaneMemorySample], thresholdBytes: Int64) -> Output {
        let clearBytes = Int64(Double(thresholdBytes) * Self.clearFraction)
        let liveKeys = Set(samples.map(\.key))
        // Forget panes that no longer exist so closed panes never keep a badge.
        warnedPanes.formIntersection(liveKeys)
        dismissedPanes.formIntersection(liveKeys)

        var bannerToPresent: PaneMemoryWarning?
        var clearedPanes: Set<PaneMemoryPaneKey> = []

        for sample in samples {
            let key = sample.key
            if sample.memoryBytes >= thresholdBytes {
                if warnedPanes.insert(key).inserted, !dismissedPanes.contains(key) {
                    // First crossing (or first since it cleared) — fire once.
                    if bannerToPresent == nil {
                        bannerToPresent = sample.warning
                    }
                }
            } else if sample.memoryBytes < clearBytes {
                warnedPanes.remove(key)
                dismissedPanes.remove(key)
                clearedPanes.insert(key)
            }
            // In the hysteresis band [clearBytes, thresholdBytes): keep state.
        }

        return Output(
            bannerToPresent: bannerToPresent,
            warnedWorkspaceIds: warnedWorkspaceIds,
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
    /// SIGTERM the pane's foreground process group(s) now, then SIGKILL after a
    /// short grace. Negative pid targets the whole process group, so the runaway
    /// job and its descendants die while the pane's shell (a different group)
    /// stays alive. ESRCH on an already-dead group is harmless.
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
    /// Fallback when a pane has no foreground process group to signal: close it.
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
            Self.computeSamples(descriptors: descriptors)
        }
        scanApplyTask = Task { @MainActor [weak self] in
            let samples = await sampleTask.value
            guard !Task.isCancelled else { return }
            self?.applySamples(samples, thresholdBytes: thresholdBytes)
        }
    }

    /// Off-main: capture one process snapshot and attribute memory per pane by
    /// controlling-tty device (the snapshot already indexes pids by tty dev).
    nonisolated static func computeSamples(descriptors: [PaneMemoryDescriptor]) -> [PaneMemorySample] {
        let snapshot = CmuxTopProcessSnapshot.capture()
        return descriptors.map { descriptor in
            guard let ttyName = descriptor.ttyName else {
                return PaneMemorySample(
                    descriptor: descriptor,
                    memoryBytes: 0,
                    residentBytes: 0,
                    foregroundProcessGroupIDs: [],
                    foregroundCommand: nil
                )
            }
            let pids = snapshot.pids(forTTYName: ttyName)
            let summary = snapshot.summary(for: pids)
            let pgids = snapshot.foregroundProcessGroupIDs(for: pids).sorted()
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                foregroundProcessGroupIDs: pgids,
                foregroundCommand: foregroundCommand
            )
        }
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

        // Banner lifecycle.
        if let active = activeBanner {
            let activeKey = PaneMemoryPaneKey(workspaceId: active.workspaceId, panelId: active.panelId)
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
        if activeBanner == nil, let toPresent = output.bannerToPresent {
            activeBanner = toPresent
        }

        if output.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = output.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(output.warnedWorkspaceIds)
        }
    }

    // MARK: Banner actions

    func dismissActiveBanner() {
        guard let active = activeBanner else { return }
        engine.dismiss(PaneMemoryPaneKey(workspaceId: active.workspaceId, panelId: active.panelId))
        activeBanner = nil
    }

    func killActivePaneProcess() {
        guard let active = activeBanner else { return }
        let key = PaneMemoryPaneKey(workspaceId: active.workspaceId, panelId: active.panelId)
        let descriptor = paneProvider?().first { $0.key == key }
        engine.acknowledgeHandled(key)
        activeBanner = nil
        if engine.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = engine.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(engine.warnedWorkspaceIds)
        }
        guard let descriptor else {
            onRequestClosePane?(active.workspaceId, active.panelId)
            return
        }
        let sampleTask = Task.detached(priority: .userInitiated) {
            Self.computeSamples(descriptors: [descriptor]).first
        }
        Task { @MainActor [weak self] in
            let pgids = await sampleTask.value?.foregroundProcessGroupIDs ?? []
            self?.finishKillActivePaneProcess(
                key: key,
                warning: active,
                processGroupIDs: pgids
            )
        }
    }

    private func finishKillActivePaneProcess(
        key: PaneMemoryPaneKey,
        warning: PaneMemoryWarning,
        processGroupIDs: [Int]
    ) {
        let pgids = processGroupIDs.filter { $0 > 1 }
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

    // MARK: Clearing

    private func clearAll() {
        engine.reset()
        isScanning = false
        scanApplyTask?.cancel()
        scanApplyTask = nil
        if activeBanner != nil { activeBanner = nil }
        lastSamplesByKey.removeAll()
        if !lastWarnedWorkspaceIds.isEmpty {
            lastWarnedWorkspaceIds = []
            onWarnedWorkspacesChanged?([])
        }
    }
}
