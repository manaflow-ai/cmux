public import CMUXMobileCore
import Foundation

/// Aggregates terminal timing locally and emits one bounded event per window.
///
/// The reporter is main-actor isolated because every terminal observation is
/// delivered by the shell's main-actor state machine. This keeps the hot path
/// free of a contended mutex. State is capped per surface, and Axiom receives
/// only ten-second summaries plus rate-limited anomalies. Terminal contents and
/// surface IDs do not leave the device.
@MainActor
public final class MobileTerminalLatencyReporter: MobileTerminalLatencyObserving {
    nonisolated public static let windowEventName = "ios_terminal_latency_window"
    nonisolated public static let anomalyEventName = "ios_terminal_latency_anomaly"

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
        var lastAnomalyAt: UInt64?

        init(windowStartedAt: UInt64) {
            self.windowStartedAt = windowStartedAt
        }
    }

    private struct WindowSnapshot: Sendable {
        let elapsedNanos: UInt64
        let inputCount: Int
        let outputCount: Int
        let presentedCount: Int
        let correlatedOutputCount: Int
        let droppedCount: Int
        let outputBytes: Int
        let maxQueueDepth: Int
        let inputToOutput: [UInt64]
        let inputToVisible: [UInt64]
        let render: [UInt64]
    }

    private struct Emission: Sendable {
        let event: String
        let properties: [String: AnalyticsValue]
    }

    private let emitter: any AnalyticsEmitting
    private let now: @Sendable () -> UInt64
    private let windowNanos: UInt64
    private var states: [String: SurfaceState] = [:]
    private let onAnomaly: (@Sendable (UInt32) -> Void)?

    nonisolated private static let maxSurfaces = 16
    nonisolated private static let maxSamples = 256
    nonisolated private static let maxInputStarts = 512
    nonisolated private static let maxOutputStarts = 128
    nonisolated private static let anomalyCooldownNanos: UInt64 = 60 * 1_000_000_000
    nonisolated private static let visibleAnomalyNanos: UInt64 = 1_000 * 1_000_000
    nonisolated private static let renderAnomalyNanos: UInt64 = 250 * 1_000_000

    public init(
        emitter: any AnalyticsEmitting,
        window: Duration = .seconds(10),
        now: (@Sendable () -> UInt64)? = nil,
        onAnomaly: (@Sendable (UInt32) -> Void)? = nil
    ) {
        self.emitter = emitter
        self.now = now ?? { DispatchTime.now().uptimeNanoseconds }
        self.windowNanos = max(
            1,
            UInt64(window.components.seconds) * 1_000_000_000
                + UInt64(window.components.attoseconds / 1_000_000_000)
        )
        self.onAnomaly = onAnomaly
    }

    public func inputStarted(surfaceID: String, byteCount: Int) -> UInt64 {
        let timestamp = now()
        guard var surface = state(for: surfaceID, now: timestamp) else { return 0 }
        surface.nextInputSequence &+= 1
        let sequence = surface.nextInputSequence
        surface.inputStarts[sequence] = InputStart(
            startedAt: timestamp,
            byteCount: max(0, byteCount)
        )
        trim(&surface.inputStarts, to: Self.maxInputStarts)
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
        return sequence
    }

    public func inputSent(surfaceID: String, sequence: UInt64) {
        let timestamp = now()
        guard var surface = states[surfaceID], surface.inputStarts[sequence] != nil else {
            return
        }
        surface.inputCount += 1
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
    }

    public func inputFailed(surfaceID: String, sequence: UInt64) {
        let timestamp = now()
        guard var surface = states[surfaceID] else { return }
        surface.inputStarts.removeValue(forKey: sequence)
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
    }

    public func outputReceived(
        surfaceID: String,
        appliedInputSequence: UInt64?,
        byteCount: Int,
        queueDepth: Int
    ) {
        let timestamp = now()
        guard var surface = state(for: surfaceID, now: timestamp) else { return }
        surface.outputCount += 1
        surface.outputBytes += max(0, byteCount)
        surface.maxQueueDepth = max(surface.maxQueueDepth, max(0, queueDepth))
        let inputStartedAt = appliedInputSequence.flatMap {
            surface.inputStarts[$0]?.startedAt
        }
        if let inputStartedAt, timestamp >= inputStartedAt {
            appendSample(timestamp - inputStartedAt, to: &surface.inputToOutput)
        }
        surface.outputs.append(OutputStart(
            receivedAt: timestamp,
            inputStartedAt: inputStartedAt
        ))
        if surface.outputs.count > Self.maxOutputStarts {
            surface.outputs.removeFirst(surface.outputs.count - Self.maxOutputStarts)
            surface.droppedCount += 1
        }
        let anomaly = inputStartedAt.flatMap { start -> UInt32? in
            guard timestamp >= start,
                  timestamp - start >= Self.visibleAnomalyNanos,
                  Self.cooldownElapsed(since: surface.lastAnomalyAt, now: timestamp) else {
                return nil
            }
            surface.lastAnomalyAt = timestamp
            return Self.durationMilliseconds(timestamp - start)
        }
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
        emitAnomaly(anomaly, thresholdMs: 1_000, stage: "input_to_output")
    }

    public func outputPresented(surfaceID: String) {
        let timestamp = now()
        guard var surface = states[surfaceID], !surface.outputs.isEmpty else { return }
        let output = surface.outputs.removeFirst()
        surface.presentedCount += 1
        var anomalyDuration: UInt32?
        if timestamp >= output.receivedAt {
            let renderDuration = timestamp - output.receivedAt
            appendSample(renderDuration, to: &surface.render)
            if renderDuration >= Self.renderAnomalyNanos,
               Self.cooldownElapsed(since: surface.lastAnomalyAt, now: timestamp) {
                surface.lastAnomalyAt = timestamp
                anomalyDuration = Self.durationMilliseconds(renderDuration)
            }
        }
        if let inputStartedAt = output.inputStartedAt, timestamp >= inputStartedAt {
            appendSample(timestamp - inputStartedAt, to: &surface.inputToVisible)
        }
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
        emitAnomaly(anomalyDuration, thresholdMs: 250, stage: "render")
    }

    public func outputDropped(surfaceID: String) {
        let timestamp = now()
        guard var surface = states[surfaceID] else { return }
        surface.droppedCount += surface.outputs.count
        surface.outputs.removeAll(keepingCapacity: true)
        emit(rolloverIfNeeded(state: &surface, now: timestamp))
        states[surfaceID] = surface
    }

    /// Snapshots state on the main actor, then sorts samples off the main actor.
    /// The only awaited work on the terminal lifecycle path is the existing
    /// analytics emitter barrier.
    public func flush() async {
        let snapshots = takeWindowSnapshots(now: now(), force: true)
        let emitter = self.emitter
        let emissions = await Task.detached(priority: nil) {
            snapshots.map(Self.makeEmission)
        }.value
        emit(emissions)
        await emitter.flush()
    }

    private func state(for surfaceID: String, now: UInt64) -> SurfaceState? {
        if let surface = states[surfaceID] { return surface }
        guard states.count < Self.maxSurfaces else { return nil }
        return SurfaceState(windowStartedAt: now)
    }

    private func takeWindowSnapshots(now: UInt64, force: Bool) -> [WindowSnapshot] {
        let surfaceIDs = Array(states.keys)
        var snapshots: [WindowSnapshot] = []
        snapshots.reserveCapacity(surfaceIDs.count)
        for surfaceID in surfaceIDs {
            guard var surface = states[surfaceID] else { continue }
            guard force || windowHasElapsed(since: surface.windowStartedAt, now: now) else {
                continue
            }
            snapshots.append(makeSnapshot(state: &surface, now: now))
            states[surfaceID] = surface
        }
        return snapshots
    }

    private func rolloverIfNeeded(
        state: inout SurfaceState,
        now: UInt64,
        force: Bool = false
    ) -> [Emission] {
        guard force || windowHasElapsed(since: state.windowStartedAt, now: now) else {
            return []
        }
        let snapshot = makeSnapshot(state: &state, now: now)
        return [Self.makeEmission(snapshot)]
    }

    private func makeSnapshot(state: inout SurfaceState, now: UInt64) -> WindowSnapshot {
        let elapsed = max(1, now >= state.windowStartedAt ? now - state.windowStartedAt : 1)
        let snapshot = WindowSnapshot(
            elapsedNanos: elapsed,
            inputCount: state.inputCount,
            outputCount: state.outputCount,
            presentedCount: state.presentedCount,
            correlatedOutputCount: state.inputToOutput.count,
            droppedCount: state.droppedCount,
            outputBytes: state.outputBytes,
            maxQueueDepth: state.maxQueueDepth,
            inputToOutput: state.inputToOutput,
            inputToVisible: state.inputToVisible,
            render: state.render
        )
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
        return snapshot
    }

    nonisolated private static func makeEmission(_ snapshot: WindowSnapshot) -> Emission {
        let properties: [String: AnalyticsValue] = [
            "window_ms": .int(milliseconds(snapshot.elapsedNanos)),
            "input_count": .int(snapshot.inputCount),
            "output_count": .int(snapshot.outputCount),
            "presented_count": .int(snapshot.presentedCount),
            "correlated_output_count": .int(snapshot.correlatedOutputCount),
            "dropped_count": .int(snapshot.droppedCount),
            "output_bytes": .int(snapshot.outputBytes),
            "max_queue_depth": .int(snapshot.maxQueueDepth),
            "input_to_output_p50_ms": .int(percentile(snapshot.inputToOutput, 0.50)),
            "input_to_output_p95_ms": .int(percentile(snapshot.inputToOutput, 0.95)),
            "input_to_output_p99_ms": .int(percentile(snapshot.inputToOutput, 0.99)),
            "input_to_visible_p50_ms": .int(percentile(snapshot.inputToVisible, 0.50)),
            "input_to_visible_p95_ms": .int(percentile(snapshot.inputToVisible, 0.95)),
            "input_to_visible_p99_ms": .int(percentile(snapshot.inputToVisible, 0.99)),
            "render_p50_ms": .int(percentile(snapshot.render, 0.50)),
            "render_p95_ms": .int(percentile(snapshot.render, 0.95)),
            "render_p99_ms": .int(percentile(snapshot.render, 0.99)),
        ]
        return Emission(event: Self.windowEventName, properties: properties)
    }

    private func emit(_ emissions: [Emission]) {
        for emission in emissions {
            emitter.capture(emission.event, emission.properties)
        }
    }

    private func emitAnomaly(_ duration: UInt32?, thresholdMs: Int, stage: String) {
        guard let duration else { return }
        emitter.capture(Self.anomalyEventName, [
            "duration_ms": .int(Int(duration)),
            "threshold_ms": .int(thresholdMs),
            "stage": .string(stage),
        ])
        onAnomaly?(duration)
    }

    nonisolated private static func cooldownElapsed(since last: UInt64?, now: UInt64) -> Bool {
        guard let last else { return true }
        return now >= last && now - last >= Self.anomalyCooldownNanos
    }

    private func windowHasElapsed(since start: UInt64, now: UInt64) -> Bool {
        now >= start && now - start >= windowNanos
    }

    nonisolated private static func milliseconds(_ nanos: UInt64) -> Int {
        Int(min(nanos / 1_000_000, UInt64(Int.max)))
    }

    nonisolated private static func durationMilliseconds(_ nanos: UInt64) -> UInt32 {
        UInt32(min(nanos / 1_000_000, UInt64(UInt32.max)))
    }

    private func appendSample(_ value: UInt64, to samples: inout [UInt64]) {
        if samples.count == Self.maxSamples {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private func trim<Value>(_ dictionary: inout [UInt64: Value], to limit: Int) {
        guard dictionary.count > limit else { return }
        dictionary.remove(at: dictionary.startIndex)
    }

    nonisolated private static func percentile(_ values: [UInt64], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return milliseconds(sorted[index])
    }
}
