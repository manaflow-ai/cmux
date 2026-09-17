public import CMUXMobileCore
import Foundation
import os

/// Aggregates terminal timing locally and emits one bounded event per window.
///
/// The observer is intentionally synchronous at the call site. A small unfair
/// lock protects capped per-surface state, and Axiom receives only ten-second
/// summaries plus rate-limited anomalies. Terminal contents and surface IDs do
/// not leave the device.
public final class MobileTerminalLatencyReporter: MobileTerminalLatencyObserving, @unchecked Sendable {
    public static let windowEventName = "ios_terminal_latency_window"
    public static let anomalyEventName = "ios_terminal_latency_anomaly"

    private struct InputStart: Sendable {
        let startedAt: UInt64
        let byteCount: Int
    }

    private struct OutputStart: Sendable {
        let receivedAt: UInt64
        let inputStartedAt: UInt64?
    }

    private struct SurfaceState: Sendable {
        var nextInputSequence: UInt64 = 0
        var windowStartedAt: UInt64
        var inputStarts: [UInt64: InputStart] = [:]
        var outputs: [OutputStart] = []
        var inputCount = 0
        var outputCount = 0
        var presentedCount = 0
        var droppedCount = 0
        var outputBytes = 0
        var maxQueueDepth = 0
        var inputToOutput: [UInt64] = []
        var inputToVisible: [UInt64] = []
        var render: [UInt64] = []
        var lastAnomalyAt: UInt64 = 0

        init(windowStartedAt: UInt64) {
            self.windowStartedAt = windowStartedAt
        }
    }

    private struct Emission: Sendable {
        let event: String
        let properties: [String: AnalyticsValue]
    }

    private let emitter: any AnalyticsEmitting
    private let now: @Sendable () -> UInt64
    private let windowNanos: UInt64
    private let state = OSAllocatedUnfairLock(initialState: [String: SurfaceState]())
    private let onAnomaly: (@Sendable (UInt32) -> Void)?

    private static let maxSurfaces = 16
    private static let maxSamples = 256
    private static let maxInputStarts = 512
    private static let maxOutputStarts = 128
    private static let anomalyCooldownNanos: UInt64 = 60 * 1_000_000_000
    private static let visibleAnomalyNanos: UInt64 = 1_000 * 1_000_000
    private static let renderAnomalyNanos: UInt64 = 250 * 1_000_000

    public init(
        emitter: any AnalyticsEmitting,
        window: Duration = .seconds(10),
        now: (@Sendable () -> UInt64)? = nil,
        onAnomaly: (@Sendable (UInt32) -> Void)? = nil
    ) {
        self.emitter = emitter
        self.now = now ?? { DispatchTime.now().uptimeNanoseconds }
        self.windowNanos = max(1, UInt64(window.components.seconds) * 1_000_000_000
            + UInt64(window.components.attoseconds / 1_000_000_000))
        self.onAnomaly = onAnomaly
    }

    public func inputStarted(surfaceID: String, byteCount: Int) -> UInt64 {
        let timestamp = now()
        let result = state.withLock { states -> (UInt64, [Emission]) in
            var surface: SurfaceState
            if let existing = states[surfaceID] {
                surface = existing
            } else {
                guard states.count < Self.maxSurfaces else { return (0, []) }
                surface = SurfaceState(windowStartedAt: timestamp)
            }
            surface.nextInputSequence &+= 1
            let sequence = surface.nextInputSequence
            surface.inputStarts[sequence] = InputStart(
                startedAt: timestamp,
                byteCount: max(0, byteCount)
            )
            trim(&surface.inputStarts, to: Self.maxInputStarts)
            let emissions = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return (sequence, emissions)
        }
        emit(result.1)
        return result.0
    }

    public func inputSent(surfaceID: String, sequence: UInt64) {
        let timestamp = now()
        let emissions = state.withLock { states -> [Emission] in
            guard var surface = states[surfaceID] else { return [] }
            guard surface.inputStarts[sequence] != nil else { return [] }
            surface.inputCount += 1
            let result = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return result
        }
        emit(emissions)
    }

    public func inputFailed(surfaceID: String, sequence: UInt64) {
        let timestamp = now()
        let emissions = state.withLock { states -> [Emission] in
            guard var surface = states[surfaceID] else { return [] }
            surface.inputStarts.removeValue(forKey: sequence)
            let result = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return result
        }
        emit(emissions)
    }

    public func outputReceived(
        surfaceID: String,
        appliedInputSequence: UInt64?,
        byteCount: Int,
        queueDepth: Int
    ) {
        let timestamp = now()
        let result = state.withLock { states -> ([Emission], UInt32?) in
            var surface: SurfaceState
            if let existing = states[surfaceID] {
                surface = existing
            } else {
                guard states.count < Self.maxSurfaces else { return ([], nil) }
                surface = SurfaceState(windowStartedAt: timestamp)
            }
            surface.outputCount += 1
            surface.outputBytes += max(0, byteCount)
            surface.maxQueueDepth = max(surface.maxQueueDepth, max(0, queueDepth))
            let inputStartedAt = appliedInputSequence.flatMap { surface.inputStarts[$0]?.startedAt }
            if let inputStartedAt, timestamp >= inputStartedAt {
                appendSample(timestamp - inputStartedAt, to: &surface.inputToOutput)
            }
            surface.outputs.append(OutputStart(receivedAt: timestamp, inputStartedAt: inputStartedAt))
            if surface.outputs.count > Self.maxOutputStarts {
                surface.outputs.removeFirst(surface.outputs.count - Self.maxOutputStarts)
                surface.droppedCount += 1
            }
            let anomaly = inputStartedAt.flatMap { start -> UInt32? in
                guard timestamp >= start,
                      timestamp - start >= Self.visibleAnomalyNanos,
                      timestamp >= surface.lastAnomalyAt + Self.anomalyCooldownNanos else { return nil }
                surface.lastAnomalyAt = timestamp
                return UInt32(min((timestamp - start) / 1_000_000, UInt64(UInt32.max)))
            }
            let emissions = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return (emissions, anomaly)
        }
        emit(result.0)
        if let duration = result.1 {
            emitter.capture(Self.anomalyEventName, [
                "duration_ms": .int(Int(duration)),
                "threshold_ms": .int(1_000),
                "stage": .string("input_to_output"),
            ])
            onAnomaly?(duration)
        }
    }

    public func outputPresented(surfaceID: String) {
        let timestamp = now()
        let result = state.withLock { states -> ([Emission], UInt32?) in
            guard var surface = states[surfaceID], !surface.outputs.isEmpty else { return ([], nil) }
            let output = surface.outputs.removeFirst()
            surface.presentedCount += 1
            var anomalyDuration: UInt32?
            if timestamp >= output.receivedAt {
                let renderDuration = timestamp - output.receivedAt
                appendSample(renderDuration, to: &surface.render)
                if renderDuration >= Self.renderAnomalyNanos,
                   timestamp >= surface.lastAnomalyAt + Self.anomalyCooldownNanos {
                    surface.lastAnomalyAt = timestamp
                    anomalyDuration = UInt32(min(renderDuration / 1_000_000, UInt64(UInt32.max)))
                }
            }
            if let inputStartedAt = output.inputStartedAt, timestamp >= inputStartedAt {
                appendSample(timestamp - inputStartedAt, to: &surface.inputToVisible)
            }
            let emissions = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return (emissions, anomalyDuration)
        }
        emit(result.0)
        if let duration = result.1 {
            emitter.capture(Self.anomalyEventName, [
                "duration_ms": .int(Int(duration)),
                "threshold_ms": .int(250),
                "stage": .string("render"),
            ])
            onAnomaly?(duration)
        }
    }

    public func outputDropped(surfaceID: String) {
        let timestamp = now()
        let emissions = state.withLock { states -> [Emission] in
            guard var surface = states[surfaceID] else { return [] }
            surface.droppedCount += surface.outputs.count
            surface.outputs.removeAll(keepingCapacity: true)
            let result = rolloverIfNeeded(surfaceID: surfaceID, state: &surface, now: timestamp)
            states[surfaceID] = surface
            return result
        }
        emit(emissions)
    }

    public func flush() async {
        let timestamp = now()
        let emissions = state.withLock { states -> [Emission] in
            var result: [Emission] = []
            for surfaceID in states.keys {
                guard var surface = states[surfaceID] else { continue }
                result.append(contentsOf: rolloverIfNeeded(
                    surfaceID: surfaceID,
                    state: &surface,
                    now: timestamp,
                    force: true
                ))
                states[surfaceID] = surface
            }
            return result
        }
        emit(emissions)
        await emitter.flush()
    }

    private func emit(_ emissions: [Emission]) {
        for emission in emissions {
            emitter.capture(emission.event, emission.properties)
        }
    }

    private func rolloverIfNeeded(
        surfaceID: String,
        state: inout SurfaceState,
        now: UInt64,
        force: Bool = false
    ) -> [Emission] {
        guard force || now >= state.windowStartedAt + windowNanos else { return [] }
        let elapsed = max(1, now - state.windowStartedAt)
        let properties: [String: AnalyticsValue] = [
            "window_ms": .int(Int(min(elapsed / 1_000_000, UInt64(Int.max)))),
            "input_count": .int(state.inputCount),
            "output_count": .int(state.outputCount),
            "presented_count": .int(state.presentedCount),
            "correlated_output_count": .int(state.inputToOutput.count),
            "dropped_count": .int(state.droppedCount),
            "output_bytes": .int(state.outputBytes),
            "max_queue_depth": .int(state.maxQueueDepth),
            "input_to_output_p50_ms": .int(percentile(state.inputToOutput, 0.50)),
            "input_to_output_p95_ms": .int(percentile(state.inputToOutput, 0.95)),
            "input_to_output_p99_ms": .int(percentile(state.inputToOutput, 0.99)),
            "input_to_visible_p50_ms": .int(percentile(state.inputToVisible, 0.50)),
            "input_to_visible_p95_ms": .int(percentile(state.inputToVisible, 0.95)),
            "input_to_visible_p99_ms": .int(percentile(state.inputToVisible, 0.99)),
            "render_p50_ms": .int(percentile(state.render, 0.50)),
            "render_p95_ms": .int(percentile(state.render, 0.95)),
            "render_p99_ms": .int(percentile(state.render, 0.99)),
        ]
        state.windowStartedAt = now
        state.inputCount = 0
        state.outputCount = 0
        state.presentedCount = 0
        state.droppedCount = 0
        state.outputBytes = 0
        state.maxQueueDepth = 0
        state.inputToOutput.removeAll(keepingCapacity: true)
        state.inputToVisible.removeAll(keepingCapacity: true)
        state.render.removeAll(keepingCapacity: true)
        return [Emission(event: Self.windowEventName, properties: properties)]
    }

    private func appendSample(_ value: UInt64, to samples: inout [UInt64]) {
        guard samples.count < Self.maxSamples else {
            samples.removeFirst()
            samples.append(value)
            return
        }
        samples.append(value)
    }

    private func trim<Value>(_ dictionary: inout [UInt64: Value], to limit: Int) {
        guard dictionary.count > limit else { return }
        dictionary.remove(at: dictionary.startIndex)
    }

    private func percentile(_ values: [UInt64], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return Int(min(sorted[index] / 1_000_000, UInt64(Int.max)))
    }
}
