import Darwin
import Foundation

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
    /// Process-group ids of the pane's dominant memory consumers — the kill
    /// target. Derived from the highest-footprint processes on the tty (not
    /// merely the foreground group) so a background leak is killed correctly.
    let runawayProcessGroupIDs: [Int]
    /// The member pids of `runawayProcessGroupIDs` captured this scan, used to
    /// revalidate the delayed SIGKILL against pid/pgid reuse.
    let runawayMemberPIDs: [Int]
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
        /// Every pane currently warned and not dismissed, highest-memory first.
        /// The monitor shows one banner at a time and pulls the next from this
        /// list when the active one is dismissed/handled, so simultaneous
        /// runaways each get an actionable banner (not just a badge).
        var presentableWarnings: [PaneMemoryWarning]
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

        var clearedPanes: Set<PaneMemoryPaneKey> = []

        for sample in samples {
            let key = sample.key
            if sample.memoryBytes >= thresholdBytes {
                warnedPanes.insert(key)
            } else if sample.memoryBytes < clearBytes {
                warnedPanes.remove(key)
                dismissedPanes.remove(key)
                clearedPanes.insert(key)
            }
            // In the hysteresis band [clearBytes, thresholdBytes): keep state.
        }

        let presentableWarnings = samples
            .filter { warnedPanes.contains($0.key) && !dismissedPanes.contains($0.key) }
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .map(\.warning)

        return Output(
            presentableWarnings: presentableWarnings,
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
    /// SIGTERM the pane's runaway process group(s) now, then escalate to SIGKILL
    /// after a short grace. `kill(-pgid, …)` targets the whole group so the
    /// runaway job and its descendants die while the pane's shell (a different
    /// group) stays alive. ESRCH on an already-dead group/pid is harmless.
    ///
    /// Both signals are validated against the captured member pids, because the
    /// sample is taken at poll time but acted on later (the banner can sit open):
    /// the sampled pgid could have exited and been reused by an unrelated
    /// process. A group is only signalled while it still contains a live
    /// captured member whose process group is unchanged, so a reused pid/pgid is
    /// never signalled — not at SIGTERM and not at the delayed SIGKILL.
    static func terminate(
        processGroupIDs: [Int],
        memberPIDs: [Int],
        graceSeconds: TimeInterval = 3
    ) {
        let candidatePGIDs = Set(processGroupIDs.filter { $0 > 1 })
        let members = memberPIDs.filter { $0 > 1 }
        guard !candidatePGIDs.isEmpty, !members.isEmpty else { return }

        // Validate at SIGTERM time: only groups that still hold a live captured
        // member with an unchanged pgid.
        let groups = liveTargetGroups(members: members, candidatePGIDs: candidatePGIDs)
        guard !groups.isEmpty else { return }
        for pgid in groups {
            _ = kill(pid_t(-pgid), SIGTERM)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + graceSeconds) {
            // Re-validate at SIGKILL time and force-kill surviving member pids
            // individually (not the group) so a reused pgid is never SIGKILLed.
            for pid in members where isMember(pid, ofGroups: groups) {
                _ = kill(pid_t(pid), SIGKILL)
            }
        }
    }

    /// The subset of `candidatePGIDs` that still contains at least one live
    /// captured member whose current process group is unchanged.
    private static func liveTargetGroups(members: [Int], candidatePGIDs: Set<Int>) -> Set<Int> {
        var groups = Set<Int>()
        for pid in members {
            guard kill(pid_t(pid), 0) == 0 else { continue }
            let currentPGID = Int(getpgid(pid_t(pid)))
            if currentPGID > 1, candidatePGIDs.contains(currentPGID) {
                groups.insert(currentPGID)
            }
        }
        return groups
    }

    private static func isMember(_ pid: Int, ofGroups pgids: Set<Int>) -> Bool {
        guard kill(pid_t(pid), 0) == 0 else { return false }
        let currentPGID = Int(getpgid(pid_t(pid)))
        return currentPGID > 1 && pgids.contains(currentPGID)
    }
}

// MARK: - Monitor

/// One instance owns the background poll timer, scans every live pane each tick,
/// attributes process-tree memory by controlling tty, and drives the per-pane
/// warning badge + dismissible banner. The heavy libproc scan runs off the main
/// thread; only the small state updates touch `@MainActor`.
@MainActor
final class PaneMemoryGuardrail: ObservableObject {
    static let shared = PaneMemoryGuardrail()

    enum DefaultsKeys {
        static let enabled = "terminal.runawayMemoryGuardrail.enabled"
        static let thresholdGB = "terminal.runawayMemoryGuardrail.thresholdGB"
    }

    private static let pollInterval: TimeInterval = 4
    private static let defaultThresholdGB: Double = 8
    private static let minThresholdGB: Double = 1

    /// The banner content for the most recent un-dismissed crossing, or nil.
    @Published private(set) var activeBanner: PaneMemoryWarning?

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Pushes the set of workspaces that should show a warning badge.
    var onWarnedWorkspacesChanged: (@MainActor (Set<UUID>) -> Void)?
    /// Fallback when a pane has no foreground process group to signal: close it.
    var onRequestClosePane: (@MainActor (_ workspaceId: UUID, _ panelId: UUID) -> Void)?

    private var engine = PaneMemoryGuardrailEngine()
    private let queue = DispatchQueue(label: "com.cmux.pane-memory-guardrail", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isScanning = false
    private var lastSamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    private var lastWarnedWorkspaceIds: Set<UUID> = []

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
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
        queue.async { [weak self] in
            let samples = Self.computeSamples(descriptors: descriptors)
            Task { @MainActor in
                self?.applySamples(samples, thresholdBytes: thresholdBytes)
            }
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
                    runawayProcessGroupIDs: [],
                    runawayMemberPIDs: [],
                    foregroundCommand: nil
                )
            }
            let pids = snapshot.pids(forTTYName: ttyName)
            let summary = snapshot.summary(for: pids)
            let processes: [(pid: Int, memoryBytes: Int64, processGroupID: Int?)] = pids.map { pid in
                let process = snapshot.process(pid: pid)
                return (pid, process?.memoryBytes ?? 0, process?.processGroupID)
            }
            let killTargets = Self.killTargetProcessGroupIDs(
                processes: processes.map { (memoryBytes: $0.memoryBytes, processGroupID: $0.processGroupID) },
                totalMemoryBytes: summary.memoryBytes
            )
            let killTargetSet = Set(killTargets)
            let memberPIDs = processes
                .filter { ($0.processGroupID).map(killTargetSet.contains) ?? false }
                .map(\.pid)
                .sorted()
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                runawayProcessGroupIDs: killTargets,
                runawayMemberPIDs: memberPIDs,
                foregroundCommand: foregroundCommand
            )
        }
    }

    /// The process group(s) to terminate for a runaway pane: every group whose
    /// largest process holds a dominant share of the pane's memory (≥ 25% of the
    /// total, and at least a small floor), so a background leak is targeted, not
    /// just whatever happens to be in the foreground. Falls back to the single
    /// highest-memory process's group when nothing clears the dominance bar.
    /// Pure and snapshot-free so it is unit-testable.
    nonisolated static func killTargetProcessGroupIDs(
        processes: [(memoryBytes: Int64, processGroupID: Int?)],
        totalMemoryBytes: Int64
    ) -> [Int] {
        let floor: Int64 = 256 * 1024 * 1024
        let dominanceThreshold = max(floor, totalMemoryBytes / 4)
        var targets = Set<Int>()
        var largest: (memoryBytes: Int64, processGroupID: Int)?
        for process in processes {
            guard let pgid = process.processGroupID, pgid > 1 else { continue }
            if process.memoryBytes >= dominanceThreshold {
                targets.insert(pgid)
            }
            if largest == nil || process.memoryBytes > largest!.memoryBytes {
                largest = (process.memoryBytes, pgid)
            }
        }
        if targets.isEmpty, let largest {
            targets.insert(largest.processGroupID)
        }
        return targets.sorted()
    }

    private func applySamples(_ samples: [PaneMemorySample], thresholdBytes: Int64) {
        isScanning = false
        lastSamplesByKey = Dictionary(samples.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })

        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        cmuxDebugLog(
            "paneMemGuard.scan panes=\(samples.count) maxMB=\(maxBytes / 1_048_576) " +
            "thresholdMB=\(thresholdBytes / 1_048_576) warned=\(output.warnedWorkspaceIds.count) " +
            "presentable=\(output.presentableWarnings.count)"
        )
#endif

        // Banner lifecycle. One banner at a time; `presentableWarnings` is the
        // queue of warned-and-undismissed panes (highest memory first).
        if let active = activeBanner {
            // Keep showing the active pane only while it is still presentable
            // (warned, not dismissed, not vanished); otherwise drop it so the
            // next queued warning can take its place.
            if let refreshed = output.presentableWarnings.first(where: { $0.panelId == active.panelId && $0.workspaceId == active.workspaceId }) {
                if refreshed != active { activeBanner = refreshed }
            } else {
                activeBanner = nil
            }
        }
        if activeBanner == nil {
            activeBanner = output.presentableWarnings.first
        }

        if output.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = output.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(output.warnedWorkspaceIds)
        }
    }

    // MARK: Banner actions

    /// Dismiss the banner for the specific `warning` the user acted on. Passing
    /// the warning (rather than reading `activeBanner`) makes the action immune
    /// to a poll-loop swap of `activeBanner` while the banner/dialog was up.
    func dismiss(_ warning: PaneMemoryWarning) {
        let key = PaneMemoryPaneKey(workspaceId: warning.workspaceId, panelId: warning.panelId)
        engine.dismiss(key)
        if let active = activeBanner,
           active.workspaceId == warning.workspaceId, active.panelId == warning.panelId {
            activeBanner = nil
        }
    }

    /// Kill the runaway process group(s) for the specific `warning` the user
    /// confirmed — NOT whatever `activeBanner` currently holds, which the poll
    /// loop may have swapped to a different pane while the confirm dialog was open.
    func killPane(_ warning: PaneMemoryWarning) {
        let key = PaneMemoryPaneKey(workspaceId: warning.workspaceId, panelId: warning.panelId)
        let sample = lastSamplesByKey[key]
        let pgids = sample?.runawayProcessGroupIDs ?? []
        if pgids.isEmpty {
            onRequestClosePane?(warning.workspaceId, warning.panelId)
        } else {
            PaneMemoryProcessKiller.terminate(
                processGroupIDs: pgids,
                memberPIDs: sample?.runawayMemberPIDs ?? []
            )
        }
        engine.acknowledgeHandled(key)
        if let active = activeBanner,
           active.workspaceId == warning.workspaceId, active.panelId == warning.panelId {
            activeBanner = nil
        }
        if engine.warnedWorkspaceIds != lastWarnedWorkspaceIds {
            lastWarnedWorkspaceIds = engine.warnedWorkspaceIds
            onWarnedWorkspacesChanged?(engine.warnedWorkspaceIds)
        }
    }

    // MARK: Clearing

    private func clearAll() {
        engine.reset()
        if activeBanner != nil { activeBanner = nil }
        lastSamplesByKey.removeAll()
        if !lastWarnedWorkspaceIds.isEmpty {
            lastWarnedWorkspaceIds = []
            onWarnedWorkspacesChanged?([])
        }
    }
}
