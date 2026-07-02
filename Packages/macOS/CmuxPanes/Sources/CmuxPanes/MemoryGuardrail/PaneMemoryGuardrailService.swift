public import Foundation
import Observation
#if DEBUG
import CMUXDebugLog
#endif

/// One instance owns the background poll timer, scans every live pane each tick,
/// and attributes process-tree memory by controlling tty. The user-facing
/// warning badge and dismissible banner were removed in issue #6614, so the scan
/// now only maintains the engine's monitoring state (surfaced in DEBUG logs) and
/// the still-wired system memory-pressure response. The heavy libproc scan runs
/// off the main thread via the injected `PaneMemorySampleProviding` seam; only
/// the small state updates touch `@MainActor`.
///
/// Constructed and wired at the app composition root: the sample provider wraps
/// the app-target process snapshot, the settings reader wraps the live
/// settings catalog, and the system-pressure callback reaches back into
/// window/browser state. There is no shared singleton.
@MainActor
@Observable
public final class PaneMemoryGuardrailService {
    private static let pollInterval: TimeInterval = 4
    private static let scopedScanInterval: TimeInterval = 15
    private static let defaultThresholdGB: Double = 8
    private static let thresholdRangeGB: ClosedRange<Double> = 1...256
    private static let bytesPerGB = 1024.0 * 1024.0 * 1024.0

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    @ObservationIgnored
    public var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Invoked when the OS reports warning/critical system memory pressure.
    @ObservationIgnored
    public var onSystemMemoryPressure: (@MainActor () -> Void)?

    /// Compatibility shim for branch-only banner UI; the banner feature was removed in issue #6614.
    public var activeBanner: PaneMemoryWarning? { nil }

    @ObservationIgnored
    private let sampleProvider: any PaneMemorySampleProviding
    @ObservationIgnored
    private let settings: any PaneMemoryGuardrailSettingsReading
    @ObservationIgnored
    private var engine = PaneMemoryGuardrailEngine()
    @ObservationIgnored
    private let timerQueue = DispatchQueue(label: "com.cmux.pane-memory-guardrail", qos: .utility)
    @ObservationIgnored
    private var timer: (any DispatchSourceTimer)?
    @ObservationIgnored
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored
    private var isScanning = false
    @ObservationIgnored
    private var scanApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    @ObservationIgnored
    private var lastScopedScanAt = Date.distantPast

    /// Creates the service from app-composed dependencies.
    ///
    /// - Parameters:
    ///   - sampleProvider: Off-main sample provider backed by the app process snapshot.
    ///   - settings: Read-only setting seam for enabled state and threshold.
    public init(
        sampleProvider: any PaneMemorySampleProviding,
        settings: any PaneMemoryGuardrailSettingsReading
    ) {
        self.sampleProvider = sampleProvider
        self.settings = settings
    }

    /// Starts the background poll timer and system memory-pressure source.
    public func start() {
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

    /// Compatibility no-op for the removed pane-memory banner.
    public func dismissActiveBanner() {}

    /// Compatibility no-op for the removed pane-memory kill action.
    ///
    /// - Parameter warning: Ignored banner warning from stale UI.
    public func killPaneProcess(for _: PaneMemoryWarning) {}

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
        CMUXDebugLog.logDebugEvent("paneMemGuard.systemMemoryPressure")
#endif
        onSystemMemoryPressure?()
    }

    // MARK: Settings

    private var isEnabled: Bool {
        settings.isEnabled
    }

    private func thresholdBytes() -> Int64 {
        let raw = settings.rawThresholdGB
        let gb = raw.isFinite
            ? min(max(raw, Self.thresholdRangeGB.lowerBound), Self.thresholdRangeGB.upperBound)
            : Self.defaultThresholdGB
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
        let sampleProvider = sampleProvider
        let sampleTask = Task.detached(priority: .utility) {
            sampleProvider.cachedSampleBatch(
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

    private func consumeScopedScanIfDue(now: Date) -> Bool {
        guard now.timeIntervalSince(lastScopedScanAt) >= Self.scopedScanInterval else {
            return false
        }
        lastScopedScanAt = now
        return true
    }

    /// Reconciles cheap scans with the last scoped-only samples so intermittent
    /// CMUX-scoped daemons do not clear between periodic expensive scans.
    public nonisolated static func reconcileScopedSamples(
        samples: [PaneMemorySample],
        currentScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        previousScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        includesCMUXScope: Bool,
        clearBytes _: Int64
    ) -> (
        samples: [PaneMemorySample],
        scopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample]
    ) {
        let liveKeys = Set(samples.map(\.key))
        let previousScopedOnlySamplesByKey = previousScopedOnlySamplesByKey.filter {
            liveKeys.contains($0.key)
        }

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

    public nonisolated static func addingScopedOnlySample(
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

        // Keep the engine's monitoring state machine current. Its warn/clear
        // output no longer drives any UI (the badge + banner were removed in
        // issue #6614); it is retained for the DEBUG scan log below.
        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
        emitScanDebugLog(
            samples: samples,
            output: output,
            thresholdBytes: thresholdBytes,
            includesCMUXScope: batch.includesCMUXScope
        )
    }

    private func emitScanDebugLog(
        samples: [PaneMemorySample],
        output: PaneMemoryGuardrailEngineOutput,
        thresholdBytes: Int64,
        includesCMUXScope: Bool
    ) {
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        CMUXDebugLog.logDebugEvent(
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
        lastScopedScanAt = .distantPast
    }
}

/// Backward-compatible name for callers migrating from the app-target guardrail.
public typealias PaneMemoryGuardrail = PaneMemoryGuardrailService
