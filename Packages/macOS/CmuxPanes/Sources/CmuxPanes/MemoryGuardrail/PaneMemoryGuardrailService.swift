public import Foundation
import Observation
#if DEBUG
import CMUXDebugLog
#endif

/// One instance owns the background poll timer, scans every live pane each tick,
/// attributes process-tree memory by controlling tty, and drives the per-pane
/// warning badge + dismissible banner. The heavy libproc scan runs off the main
/// thread via the injected `PaneMemorySampleProviding` seam; only the small
/// state updates touch `@MainActor`.
///
/// Constructed and wired at the app composition root: the sample provider wraps
/// the app-target process snapshot, the settings reader wraps the live
/// `SettingCatalog`, and the callbacks reach back into window/notification state.
/// There is no shared singleton.
@MainActor
@Observable
public final class PaneMemoryGuardrailService {
    private static let pollInterval: TimeInterval = 4
    private static let defaultThresholdGB: Double = 8
    private static let thresholdRangeGB: ClosedRange<Double> = 1...256
    private static let bytesPerGB = 1024.0 * 1024.0 * 1024.0

    /// The banner content for the most recent un-dismissed crossing, or nil.
    public private(set) var activeBanner: PaneMemoryWarning?

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    @ObservationIgnored
    public var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Pushes the set of workspaces that should show a warning badge.
    @ObservationIgnored
    public var onWarnedWorkspacesChanged: (@MainActor (Set<UUID>) -> Void)?
    /// Fallback when a pane has no high-memory process group to signal: close it.
    @ObservationIgnored
    public var onRequestClosePane: (@MainActor (_ workspaceId: UUID, _ panelId: UUID) -> Void)?

    @ObservationIgnored
    private let sampleProvider: any PaneMemorySampleProviding
    @ObservationIgnored
    private let settings: any PaneMemoryGuardrailSettingsReading
    @ObservationIgnored
    private var engine = PaneMemoryGuardrailEngine()
    // The poll timer fires on the main queue: this service is `@MainActor`, so
    // the `setEventHandler` closure the compiler synthesizes carries a MainActor
    // isolation assertion, and running it on a background queue traps at runtime
    // (`swift_task_isCurrentExecutor` → `dispatch_assert_queue_fail`) on
    // macOS 26 / Swift 6. `tick()` only kicks off `Task.detached` sampling, so
    // the main-queue cost is a periodic guard + dispatch, not the heavy scan.
    @ObservationIgnored
    private let timerQueue = DispatchQueue.main
    @ObservationIgnored
    private var timer: (any DispatchSourceTimer)?
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

    public init(
        sampleProvider: any PaneMemorySampleProviding,
        settings: any PaneMemoryGuardrailSettingsReading
    ) {
        self.sampleProvider = sampleProvider
        self.settings = settings
    }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .seconds(1)
        )
        // `timerQueue` is the main queue (see its declaration), so the handler
        // runs on the main thread and MainActor isolation holds when we call
        // `tick()`.
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()
    }

    // MARK: Settings

    private var isEnabled: Bool {
        settings.isEnabled
    }

    private func thresholdBytes() -> Int64 {
        let raw = settings.rawThresholdGB
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
        isScanning = true
        let sampleProvider = sampleProvider
        let sampleTask = Task.detached(priority: .utility) {
            sampleProvider.cachedSamples(descriptors: descriptors, thresholdBytes: thresholdBytes)
        }
        scanApplyTask = Task { @MainActor [weak self] in
            let samples = await sampleTask.value
            guard !Task.isCancelled else { return }
            self?.applySamples(samples, thresholdBytes: thresholdBytes)
        }
    }

    private func applySamples(_ samples: [PaneMemorySample], thresholdBytes: Int64) {
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
        CMUXDebugLog.logDebugEvent(
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

    public func dismissActiveBanner() {
        guard let active = activeBanner else { return }
        engine.dismiss(active.key)
        pendingBanners.removeAll { $0.key == active.key }
        activeBanner = nil
        presentNextPendingBannerIfNeeded()
    }

    public func killActivePaneProcess() { if let active = activeBanner { killPaneProcess(for: active) } }

    public func killPaneProcess(for warning: PaneMemoryWarning) {
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
        let sampleProvider = sampleProvider
        let sampleTask = Task.detached(priority: .userInitiated) {
            sampleProvider.freshSamples(descriptors: [descriptor], thresholdBytes: thresholdBytes).first
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
        let sampleProvider = sampleProvider
        guard let task = killer.terminate(
            processGroupIDs: pgids,
            validateBeforeSIGKILL: {
                let freshSample = sampleProvider.freshSamples(
                    descriptors: [descriptor],
                    thresholdBytes: thresholdBytes
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
        pendingKillTasksByKey.values.forEach { $0.task.cancel() }
        pendingKillTasksByKey.removeAll()
        if !lastWarnedWorkspaceIds.isEmpty {
            lastWarnedWorkspaceIds = []
            onWarnedWorkspacesChanged?([])
        }
    }
}
