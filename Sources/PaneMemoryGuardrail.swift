import CmuxSettings
import Foundation
import Observation

// MARK: - Monitor

/// One instance owns the background poll timer, scans every live pane each tick,
/// attributes process-tree memory by controlling tty, and drives the per-pane
/// warning badge + dismissible banner. The heavy libproc scan runs off the main
/// thread; only the small state updates touch `@MainActor`.
@MainActor
@Observable
final class PaneMemoryGuardrail {
    static let shared = PaneMemoryGuardrail()

    private static let enabledSetting = SettingCatalog().terminal.runawayMemoryGuardrailEnabled
    private static let thresholdGBSetting = SettingCatalog().terminal.runawayMemoryGuardrailThresholdGB
    private static let pollInterval: TimeInterval = 4
    private static let scopedScanInterval: TimeInterval = 15
    private static let defaultThresholdGB: Double = 8
    private static let thresholdRangeGB: ClosedRange<Double> = 1...256
    private static let bytesPerGB = 1024.0 * 1024.0 * 1024.0

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
    private var lastScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    @ObservationIgnored
    private var lastWarnedWorkspaceIds: Set<UUID> = []
    @ObservationIgnored
    private var lastScopedScanAt = Date.distantPast
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

    nonisolated static func computeFreshSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        includeCMUXScope: Bool = false
    ) -> [PaneMemorySample] {
        computeSamples(
            descriptors: descriptors,
            thresholdBytes: thresholdBytes,
            snapshot: CmuxTopProcessSnapshot.capture(includeCMUXScope: includeCMUXScope)
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
        let samplesByKey = Dictionary(samples.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        lastSamplesByKey = samplesByKey
        for key in Array(pendingKillTasksByKey.keys) where samplesByKey[key] == nil {
            pendingKillTasksByKey.removeValue(forKey: key)?.task.cancel()
        }

        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        cmuxDebugLog(
            "paneMemGuard.scan panes=\(samples.count) maxMB=\(maxBytes / 1_048_576) " +
            "thresholdMB=\(thresholdBytes / 1_048_576) warned=\(output.warnedWorkspaceIds.count) " +
            "fired=\(output.bannerToPresent != nil ? 1 : 0) scope=\(batch.includesCMUXScope ? 1 : 0)"
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
            Self.computeFreshSamples(
                descriptors: [descriptor],
                thresholdBytes: thresholdBytes,
                includeCMUXScope: true
            ).first
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
        let descriptor = sample.descriptor
        let killer = PaneMemoryProcessKiller()
        guard let task = killer.terminate(
            processGroupIDs: pgids,
            validateBeforeSIGKILL: {
                let freshSample = Self.computeFreshSamples(
                    descriptors: [descriptor],
                    thresholdBytes: thresholdBytes,
                    includeCMUXScope: true
                ).first
                guard let freshSample, freshSample.memoryBytes >= thresholdBytes else {
                    return []
                }
                return Set(freshSample.memoryPressureProcessGroupIDs.filter { $0 > 1 })
            }
        ) else { return }
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
        lastScopedOnlySamplesByKey.removeAll()
        lastScopedScanAt = .distantPast
        pendingKillTasksByKey.values.forEach { $0.task.cancel() }
        pendingKillTasksByKey.removeAll()
        if !lastWarnedWorkspaceIds.isEmpty {
            lastWarnedWorkspaceIds = []
            onWarnedWorkspacesChanged?([])
        }
    }
}
