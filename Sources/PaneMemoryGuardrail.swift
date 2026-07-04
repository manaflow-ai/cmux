import CmuxSettings
import Foundation
import Observation

// MARK: - Monitor

/// One instance owns the background poll timer, scans every live pane each tick,
/// and attributes process-tree memory by controlling tty. When a pane's process
/// tree first crosses the configurable threshold the guardrail fires
/// `onPaneRunaway` (issue #6313) so the app can post a calm, per-pane
/// notification before macOS can OOM-suspend the whole app. The intrusive
/// sidebar warning badge + dismissible "kill pane" banner from the original
/// feature were removed in issue #6614 and are deliberately not reintroduced;
/// the notification reuses the standard notification channel instead. The scan
/// also drives the still-wired system memory-pressure response. The heavy
/// libproc scan runs off the main thread; only the small state updates touch
/// `@MainActor`.
@MainActor
@Observable
final class PaneMemoryGuardrail {
    static let shared = PaneMemoryGuardrail()

    private static let enabledSetting = SettingCatalog().terminal.runawayMemoryGuardrailEnabled
    private static let thresholdGBSetting = SettingCatalog().terminal.runawayMemoryGuardrailThresholdGB
    private static let pollInterval: TimeInterval = 4
    private static let scopedScanInterval: TimeInterval = 15
    /// Re-notify the same pane at most once per this interval, even if it keeps
    /// flapping across the engine's clear/threshold band, so a leak can't spam.
    private static let runawayNotificationCooldown: TimeInterval = 300
    private static let defaultThresholdGB: Double = 8
    private static let thresholdRangeGB: ClosedRange<Double> = 1...256
    private static let bytesPerGB = 1024.0 * 1024.0 * 1024.0

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    @ObservationIgnored
    var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Invoked when the OS reports warning/critical system memory pressure.
    @ObservationIgnored
    var onSystemMemoryPressure: (@MainActor () -> Void)?
    /// Invoked with each pane that first crossed the runaway-memory threshold
    /// this tick (edge-triggered, hysteresis-cleared by the engine). Wired to a
    /// per-pane in-app notification so a leaking process is observable before it
    /// OOM-suspends the app (issue #6313).
    @ObservationIgnored
    var onPaneRunaway: (@MainActor ([PaneMemoryWarning]) -> Void)?

    @ObservationIgnored
    private var engine = PaneMemoryGuardrailEngine()
    @ObservationIgnored
    private let timerQueue = DispatchQueue(label: "com.cmux.pane-memory-guardrail", qos: .utility)
    @ObservationIgnored
    private var timer: DispatchSourceTimer?
    @ObservationIgnored
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored
    private var isScanning = false
    @ObservationIgnored
    private var scanApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    /// When each live pane was last notified about a runaway tree, so we can
    /// rate-limit per pane. Pruned to the live pane set every tick, so it can
    /// never grow without bound as panes open and close.
    @ObservationIgnored
    private var lastRunawayNotificationAt: [PaneMemoryPaneKey: Date] = [:]
    @ObservationIgnored
    private var lastScopedScanAt = Date.distantPast

    func start() {
        startSystemMemoryPressureSourceIfNeeded()
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

    private func startSystemMemoryPressureSourceIfNeeded() {
        guard memoryPressureSource == nil else { return }
        // DispatchSource memory-pressure notifications are the system signal for
        // freeing nonessential WebKit process memory; no async-native equivalent
        // exists.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: timerQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleSystemMemoryPressure()
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func handleSystemMemoryPressure() {
#if DEBUG
        cmuxDebugLog("paneMemGuard.systemMemoryPressure")
#endif
        onSystemMemoryPressure?()
    }

    // MARK: Settings

    private var isEnabled: Bool {
        Self.enabledSetting.value(in: .standard)
    }

    private func thresholdBytes() -> Int64 {
        let raw = Self.thresholdGBSetting.value(in: .standard)
        let gb = raw.isFinite ? min(max(raw, Self.thresholdRangeGB.lowerBound), Self.thresholdRangeGB.upperBound) : Self.defaultThresholdGB
        return Int64(gb * Self.bytesPerGB)
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
        let includeCMUXScope = consumeScopedScanIfDue(now: Date())
        isScanning = true
        let sampleTask = Task.detached(priority: .utility) {
            Self.computeCachedSamples(
                descriptors: descriptors,
                thresholdBytes: thresholdBytes,
                includeCMUXScope: includeCMUXScope
            )
        }
        scanApplyTask = Task { @MainActor [weak self] in
            let batch = await sampleTask.value
            guard !Task.isCancelled else { return }
            self?.applySamples(
                batch,
                thresholdBytes: thresholdBytes
            )
        }
    }

    nonisolated static func computeCachedSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        includeCMUXScope: Bool = false
    ) -> PaneMemoryGuardrailSampleBatch {
        let snapshot = includeCMUXScope
            ? CmuxTopProcessSnapshot.capture(includeCMUXScope: true)
            : CmuxTopProcessSnapshot.captureCached(includeCMUXScope: false, maximumAge: 2)
        let samples = computeSamples(
            descriptors: descriptors,
            thresholdBytes: thresholdBytes,
            snapshot: snapshot
        )
        let scopedOnlySamples = snapshot.hasCMUXScope
            ? computeScopedOnlySamples(
                descriptors: descriptors,
                thresholdBytes: thresholdBytes,
                snapshot: snapshot
            )
            : []
        return PaneMemoryGuardrailSampleBatch(
            samples: samples,
            scopedOnlySamplesByKey: Dictionary(
                scopedOnlySamples.map { ($0.key, $0) },
                uniquingKeysWith: { _, last in last }
            ),
            includesCMUXScope: snapshot.hasCMUXScope
        )
    }

    nonisolated static func computeSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        snapshot: CmuxTopProcessSnapshot
    ) -> [PaneMemorySample] {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            var rootPIDs = snapshot.pids(forCMUXSurfaceID: descriptor.panelId)
            if let foregroundPID = descriptor.foregroundPID {
                rootPIDs.insert(foregroundPID)
            }
            if let ttyName = descriptor.ttyName {
                rootPIDs.formUnion(snapshot.pids(forTTYName: ttyName))
            }
            let pids = snapshot.expandedPIDs(rootPIDs: rootPIDs)
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

    nonisolated static func computeScopedOnlySamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        snapshot: CmuxTopProcessSnapshot
    ) -> [PaneMemorySample] {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            let cheapPIDs = snapshot.expandedPIDs(rootPIDs: cheapRootPIDs(for: descriptor, in: snapshot))
            let scopedPIDs = snapshot.expandedPIDs(rootPIDs: snapshot.pids(forCMUXSurfaceID: descriptor.panelId))
            let scopedOnlyPIDs = scopedPIDs.subtracting(cheapPIDs)
            let summary = snapshot.summary(for: scopedOnlyPIDs)
            let pgids = memoryPressureProcessGroupIDs(
                in: snapshot,
                pids: scopedOnlyPIDs,
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

    nonisolated static func cheapRootPIDs(
        for descriptor: PaneMemoryDescriptor,
        in snapshot: CmuxTopProcessSnapshot
    ) -> Set<Int> {
        var rootPIDs: Set<Int> = []
        if let foregroundPID = descriptor.foregroundPID {
            rootPIDs.insert(foregroundPID)
        }
        if let ttyName = descriptor.ttyName {
            rootPIDs.formUnion(snapshot.pids(forTTYName: ttyName))
        }
        return rootPIDs
    }

    private func consumeScopedScanIfDue(now: Date) -> Bool {
        guard now.timeIntervalSince(lastScopedScanAt) >= Self.scopedScanInterval else {
            return false
        }
        lastScopedScanAt = now
        return true
    }

    nonisolated static func reconcileScopedSamples(
        samples: [PaneMemorySample],
        currentScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        previousScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        includesCMUXScope: Bool,
        clearBytes: Int64
    ) -> (
        samples: [PaneMemorySample],
        scopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample]
    ) {
        let liveKeys = Set(samples.map(\.key))
        let previousScopedOnlySamplesByKey = previousScopedOnlySamplesByKey.filter { liveKeys.contains($0.key) }

        if includesCMUXScope {
            let scopedOnlySamplesByKey = currentScopedOnlySamplesByKey.filter {
                liveKeys.contains($0.key) && $0.value.memoryBytes > 0
            }
            return (samples, scopedOnlySamplesByKey)
        }

        let mergedSamples = samples.map { sample in
            guard let scopedOnlySample = previousScopedOnlySamplesByKey[sample.key] else {
                return sample
            }
            return addingScopedOnlySample(scopedOnlySample, to: sample)
        }
        return (mergedSamples, previousScopedOnlySamplesByKey)
    }

    nonisolated static func addingScopedOnlySample(
        _ scopedOnlySample: PaneMemorySample,
        to sample: PaneMemorySample
    ) -> PaneMemorySample {
        let memoryBytes = saturatingAdd(sample.memoryBytes, scopedOnlySample.memoryBytes)
        let residentBytes = saturatingAdd(sample.residentBytes, scopedOnlySample.residentBytes)
        let pgids = Array(Set(sample.memoryPressureProcessGroupIDs)
            .union(scopedOnlySample.memoryPressureProcessGroupIDs))
            .sorted()
        return PaneMemorySample(
            descriptor: sample.descriptor,
            memoryBytes: memoryBytes,
            residentBytes: residentBytes,
            memoryPressureProcessGroupIDs: pgids,
            foregroundCommand: sample.foregroundCommand
        )
    }

    nonisolated private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
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

    /// Rate-limits the engine's edge-triggered crossings to one notification per
    /// pane per `cooldown`, and prunes `lastNotifiedAt` to the live pane set so
    /// it can never grow without bound as panes open and close. Pure and
    /// `nonisolated` so the policy is testable without timers, ghostty, or libproc.
    nonisolated static func runawayNotificationsToPresent(
        bannersToPresent: [PaneMemoryWarning],
        liveKeys: Set<PaneMemoryPaneKey>,
        now: Date,
        cooldown: TimeInterval,
        lastNotifiedAt: inout [PaneMemoryPaneKey: Date]
    ) -> [PaneMemoryWarning] {
        // Forget closed panes first so the rate-limit map stays bounded.
        lastNotifiedAt = lastNotifiedAt.filter { liveKeys.contains($0.key) }
        var toPresent: [PaneMemoryWarning] = []
        for warning in bannersToPresent {
            let key = warning.key
            if let last = lastNotifiedAt[key], now.timeIntervalSince(last) < cooldown {
                continue
            }
            lastNotifiedAt[key] = now
            toPresent.append(warning)
        }
        return toPresent
    }

    private func applySamples(
        _ batch: PaneMemoryGuardrailSampleBatch,
        thresholdBytes: Int64
    ) {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        let reconciled = Self.reconcileScopedSamples(
            samples: batch.samples,
            currentScopedOnlySamplesByKey: batch.scopedOnlySamplesByKey,
            previousScopedOnlySamplesByKey: lastScopedOnlySamplesByKey,
            includesCMUXScope: batch.includesCMUXScope,
            clearBytes: clearBytes
        )
        lastScopedOnlySamplesByKey = reconciled.scopedOnlySamplesByKey
        let samples = reconciled.samples
        isScanning = false
        scanApplyTask = nil

        // Advance the engine's edge-trigger + hysteresis state machine. Each
        // pane that newly crossed the threshold this tick is surfaced as a calm
        // per-pane notification (issue #6313); the bespoke badge + dismissible
        // banner were removed in issue #6614 and are not reintroduced here.
        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
        let toNotify = Self.runawayNotificationsToPresent(
            bannersToPresent: output.bannersToPresent,
            liveKeys: Set(samples.map(\.key)),
            now: Date(),
            cooldown: Self.runawayNotificationCooldown,
            lastNotifiedAt: &lastRunawayNotificationAt
        )
        if !toNotify.isEmpty {
            onPaneRunaway?(toNotify)
        }
        emitScanDebugLog(samples: samples, output: output, thresholdBytes: thresholdBytes, includesCMUXScope: batch.includesCMUXScope)
    }

    private func emitScanDebugLog(
        samples: [PaneMemorySample],
        output: PaneMemoryGuardrailEngineOutput,
        thresholdBytes: Int64,
        includesCMUXScope: Bool
    ) {
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        cmuxDebugLog(
            "paneMemGuard.scan panes=\(samples.count) maxMB=\(maxBytes / 1_048_576) " +
            "thresholdMB=\(thresholdBytes / 1_048_576) warned=\(output.warnedWorkspaceIds.count) " +
            "scope=\(includesCMUXScope ? 1 : 0)"
        )
#endif
    }

    // MARK: Clearing

    private func clearAll() {
        engine.reset()
        isScanning = false
        scanApplyTask?.cancel()
        scanApplyTask = nil
        lastScopedOnlySamplesByKey.removeAll()
        lastRunawayNotificationAt.removeAll()
        lastScopedScanAt = .distantPast
    }
}
