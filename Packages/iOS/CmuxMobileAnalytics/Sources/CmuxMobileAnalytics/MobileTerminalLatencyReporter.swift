public import CMUXMobileCore
import Foundation

/// Bounded counters on the shell actor; one aggregate per active ten-second window.
/// Input markers are opaque, session-randomized values carried over the wire. They
/// identify post-acceptance output, not proof that a command caused that output.
@MainActor
public final class MobileTerminalLatencyReporter: MobileTerminalLatencyObserving {
    nonisolated public static let windowEventName = "ios_terminal_latency_window"
    nonisolated public static let anomalyEventName = "ios_terminal_latency_anomaly"
    // Shared histogram schema v1. The last bucket includes values >= 32768ms.
    nonisolated static let bucketBoundsMs = (0..<16).map { 1 << $0 } + [60_000]

    private struct Window: Sendable {
        var inputCount = 0
        var failedCount = 0
        var outputCount = 0
        var appliedCount = 0
        var presentedCount = 0
        var droppedCount = 0
        var outputBytes = 0
        var maxQueueDepth = 0
        var inputToOutput = Array(repeating: 0, count: 17)
        var inputToVisible = Array(repeating: 0, count: 17)
        var render = Array(repeating: 0, count: 17)
        var hasActivity: Bool { inputCount > 0 || failedCount > 0 || outputCount > 0 || presentedCount > 0 || droppedCount > 0 }
    }

    private final class SurfaceState {
        var window = Window()
        var windowStartedAt: UInt64
        var activeWindowNanos: UInt64 = 0
        var lastActivityAt: UInt64
        var inputStarts: [UInt64: UInt64] = [:]
        var presentationStarts: [UInt64: UInt64] = [:]
        var firstReceivedAt: UInt64?
        var lastPresentedReceipt: UInt64 = 0
        var lastAnomalyAt: [String: UInt64] = [:]
        var consecutiveSlowFrames = 0
        init(now: UInt64) { windowStartedAt = now; lastActivityAt = now }
    }

    private struct Snapshot: Sendable {
        let window: Window
        let elapsedNanos: UInt64
    }

    private let emitter: any AnalyticsEmitting
    private let now: @MainActor @Sendable () -> UInt64
    private let window: Duration
    private let consent: any AnalyticsConsentProviding
    private let onAnomaly: (@Sendable (UInt32) -> Void)?
    private var states: [String: SurfaceState] = [:]
    private var nextSequence = UInt64.random(in: 1...(UInt64.max / 2))
    private var enabled = true
    private var isForeground = true
    private var foregroundStartedAt: UInt64 = 0
    private var cadenceTask: Task<Void, Never>?

    public init(
        emitter: any AnalyticsEmitting,
        window: Duration = .seconds(10),
        now: (@MainActor @Sendable () -> UInt64)? = nil,
        consent: any AnalyticsConsentProviding = EnabledTerminalLatencyConsent(),
        onAnomaly: (@Sendable (UInt32) -> Void)? = nil
    ) {
        self.emitter = emitter
        self.window = max(.milliseconds(1), window)
        self.now = now ?? { DispatchTime.now().uptimeNanoseconds }
        self.consent = consent
        self.onAnomaly = onAnomaly
    }

    deinit { cadenceTask?.cancel() }

    /// Disabling stops both sampling and scheduled work immediately.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            states.removeAll()
            cadenceTask?.cancel()
            cadenceTask = nil
        }
    }

    /// Suspension and permission prompts are not terminal responsiveness samples.
    public func setForeground(_ active: Bool) {
        guard active != isForeground else { return }
        let timestamp = now()
        for surface in states.values {
            if active {
                surface.windowStartedAt = timestamp
            } else if timestamp >= surface.windowStartedAt {
                surface.activeWindowNanos += timestamp - surface.windowStartedAt
            }
        }
        isForeground = active
        if active { foregroundStartedAt = timestamp }
        else {
            cadenceTask?.cancel()
            cadenceTask = nil
            for surface in states.values {
                surface.inputStarts.removeAll(keepingCapacity: true)
                surface.presentationStarts.removeAll(keepingCapacity: true)
                surface.consecutiveSlowFrames = 0
                surface.firstReceivedAt = nil
            }
        }
    }

    public func inputStarted(surfaceID: String, byteCount: Int) -> UInt64 {
        guard let surface = state(for: surfaceID) else { return 0 }
        nextSequence &+= 1
        surface.window.inputCount += 1
        surface.inputStarts[nextSequence] = now()
        trim(&surface.inputStarts)
        return nextSequence
    }

    public func inputSent(surfaceID: String, sequence: UInt64) {}

    public func inputFailed(surfaceID: String, sequence: UInt64) {
        guard isForeground, let surface = states[surfaceID] else { return }
        surface.inputStarts[sequence] = nil
        surface.presentationStarts[sequence] = nil
        surface.window.failedCount += 1
    }

    public func outputReceived(surfaceID: String, appliedInputSequence: UInt64?, byteCount: Int, queueDepth: Int, receivedAtNanos: UInt64? = nil) {
        guard let surface = state(for: surfaceID) else { return }
        let timestamp = receivedAtNanos ?? now()
        if surface.firstReceivedAt == nil { surface.firstReceivedAt = timestamp }
        surface.window.outputCount += 1
        surface.window.outputBytes += max(0, byteCount)
        surface.window.maxQueueDepth = max(surface.window.maxQueueDepth, queueDepth)
        // Consume once. A later frame with the same watermark is ordinary output.
        if let sequence = appliedInputSequence,
           let start = surface.inputStarts.removeValue(forKey: sequence), timestamp >= start {
            Self.record(timestamp - start, in: &surface.window.inputToOutput)
            surface.presentationStarts[sequence] = start
            // Input arrives in order. A known cumulative watermark also covers
            // earlier outstanding inputs from this session. Keep their waits so
            // a burst cannot hide a stall behind its newest, quickest key.
            for (earlier, queued) in surface.inputStarts where earlier < sequence && timestamp >= queued {
                Self.record(timestamp - queued, in: &surface.window.inputToOutput)
                surface.presentationStarts[earlier] = queued
                surface.inputStarts[earlier] = nil
                emitAnomaly(timestamp - queued, thresholdMs: 1_000, stage: "input_to_output", surface: surface)
            }
            trim(&surface.presentationStarts)
            emitAnomaly(timestamp - start, thresholdMs: 1_000, stage: "input_to_output", surface: surface)
        }
    }

    /// The output queue acknowledgment records application, not GPU presentation.
    public func outputApplied(surfaceID: String) {
        states[surfaceID]?.window.appliedCount += 1
    }

    public func framePresented(surfaceID: String, inputSequence: UInt64?, receivedAtNanos: UInt64) {
        guard isForeground, enabled, consent.isTelemetryEnabled,
              receivedAtNanos >= foregroundStartedAt,
              let surface = states[surfaceID], let firstReceipt = surface.firstReceivedAt,
              receivedAtNanos >= firstReceipt, receivedAtNanos > surface.lastPresentedReceipt else { return }
        let timestamp = now()
        guard timestamp >= receivedAtNanos else { return }
        surface.lastActivityAt = timestamp
        surface.lastPresentedReceipt = receivedAtNanos
        surface.window.presentedCount += 1
        let duration = timestamp - receivedAtNanos
        Self.record(duration, in: &surface.window.render)
        if let sequence = inputSequence, let start = surface.presentationStarts.removeValue(forKey: sequence), timestamp >= start {
            Self.record(timestamp - start, in: &surface.window.inputToVisible)
            for (earlier, queued) in surface.presentationStarts where earlier < sequence && timestamp >= queued {
                Self.record(timestamp - queued, in: &surface.window.inputToVisible)
                surface.presentationStarts[earlier] = nil
            }
        }
        surface.consecutiveSlowFrames = duration >= 250_000_000 ? surface.consecutiveSlowFrames + 1 : 0
        emitAnomaly(duration, thresholdMs: 250, stage: "render", surface: surface)
    }

    public func outputDropped(surfaceID: String) {
        guard isForeground, let surface = states[surfaceID] else { return }
        surface.window.droppedCount += 1
        surface.inputStarts.removeAll(keepingCapacity: true)
        surface.presentationStarts.removeAll(keepingCapacity: true)
    }

    /// Copies small histograms on main, builds event dictionaries off main.
    public func flush() async {
        let timestamp = now()
        guard enabled, consent.isTelemetryEnabled else {
            states.removeAll()
            return
        }
        var snapshots: [Snapshot] = []
        for surface in states.values {
            if surface.window.hasActivity {
                // A window can cross inactive scenes before its asynchronous
                // flush runs. Count only its active segments, preserving both
                // counters and their duration through delayed lifecycle work.
                let currentSegment = isForeground && timestamp >= surface.windowStartedAt ? timestamp - surface.windowStartedAt : 0
                snapshots.append(Snapshot(window: surface.window, elapsedNanos: surface.activeWindowNanos + currentSegment))
                surface.window = Window()
            }
            surface.activeWindowNanos = 0
            surface.windowStartedAt = timestamp
            // No output is normal for some inputs. Expiry is missing coverage,
            // never an invented slow response or Sentry incident.
            surface.inputStarts = surface.inputStarts.filter { timestamp >= $0.value && timestamp - $0.value < 30_000_000_000 }
            surface.presentationStarts = surface.presentationStarts.filter { timestamp >= $0.value && timestamp - $0.value < 30_000_000_000 }
        }
        states = states.filter { timestamp >= $0.value.lastActivityAt && timestamp - $0.value.lastActivityAt < 60_000_000_000 }
        let emitter = self.emitter
        await Task.detached(priority: .utility) {
            for snapshot in snapshots { emitter.capture(Self.windowEventName, Self.properties(snapshot)) }
            await emitter.flush()
        }.value
    }

    private func state(for surfaceID: String) -> SurfaceState? {
        guard isForeground else { return nil }
        guard enabled, consent.isTelemetryEnabled else { states.removeAll(); return nil }
        let timestamp = now()
        let surface: SurfaceState
        if let existing = states[surfaceID] { surface = existing }
        else {
            if states.count == 16, let oldest = states.min(by: { $0.value.lastActivityAt < $1.value.lastActivityAt })?.key { states[oldest] = nil }
            surface = SurfaceState(now: timestamp)
            states[surfaceID] = surface
        }
        surface.lastActivityAt = timestamp
        if cadenceTask == nil {
            let interval = window
            cadenceTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard let self else { return }
                    await self.flush()
                    if self.states.isEmpty { self.cadenceTask = nil; return }
                }
            }
        }
        return surface
    }

    private func trim(_ values: inout [UInt64: UInt64]) {
        if values.count > 512, let oldest = values.min(by: { $0.value < $1.value })?.key { values[oldest] = nil }
    }

    private func emitAnomaly(_ duration: UInt64, thresholdMs: Int, stage: String, surface: SurfaceState) {
        guard duration / 1_000_000 >= thresholdMs else { return }
        let timestamp = now()
        guard surface.lastAnomalyAt[stage].map({ timestamp >= $0 && timestamp - $0 >= 60_000_000_000 }) ?? true else { return }
        // Sentry requires repeated slow presentations. Individual slow responses
        // remain Axiom observations because shell/program execution may be slow.
        if stage == "render", surface.consecutiveSlowFrames < 3 { return }
        surface.lastAnomalyAt[stage] = timestamp
        let ms = Int(min(duration / 1_000_000, UInt64(UInt32.max)))
        emitter.capture(Self.anomalyEventName, ["duration_ms": .int(ms), "threshold_ms": .int(thresholdMs), "stage": .string(stage)])
        if stage == "render" { onAnomaly?(UInt32(ms)) }
    }

    nonisolated private static func record(_ nanos: UInt64, in histogram: inout [Int]) {
        let ms = (nanos + 999_999) / 1_000_000
        let bucket = bucketBoundsMs.firstIndex { ms <= $0 } ?? 16
        histogram[bucket] += 1
    }

    nonisolated private static func properties(_ snapshot: Snapshot) -> [String: AnalyticsValue] {
        let w = snapshot.window
        var values: [String: AnalyticsValue] = [
            "window_ms": .int(Int(snapshot.elapsedNanos / 1_000_000)),
            "input_count": .int(w.inputCount), "input_failed_count": .int(w.failedCount),
            "output_count": .int(w.outputCount), "presented_count": .int(w.presentedCount),
            "correlated_output_count": .int(w.inputToOutput.reduce(0, +)),
            "dropped_count": .int(w.droppedCount), "output_bytes": .int(w.outputBytes),
            "max_queue_depth": .int(w.maxQueueDepth), "histogram_version": .int(1),
        ]
        for (name, histogram) in [("input_to_output", w.inputToOutput), ("input_to_visible", w.inputToVisible), ("render", w.render)] {
            values["\(name)_histogram"] = .string("[" + histogram.map(String.init).joined(separator: ",") + "]")
            let count = histogram.reduce(0, +)
            for percentile in [50, 95, 99] {
                var cumulative = 0
                let rank = max(1, (count * percentile + 99) / 100)
                let index = histogram.indices.first { cumulative += histogram[$0]; return cumulative >= rank }
                values["\(name)_p\(percentile)_ms"] = .int(index.map { bucketBoundsMs[$0] } ?? 0)
            }
        }
        return values
    }
}

/// Default for callers that already gate observations upstream.
public struct EnabledTerminalLatencyConsent: AnalyticsConsentProviding {
    public init() {}
    public var isTelemetryEnabled: Bool { true }
}
