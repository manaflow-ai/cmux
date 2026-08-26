import CmuxMobileRPC
import CmuxSimulatorStreamKit
import CoreMedia
import Foundation

/// Display seam between the engine and the render layer. Implementations
/// hop to the main actor internally; returning `false` from `present` means
/// the frame was NOT displayed, so the engine must not acknowledge it (which
/// stalls host credit instead of letting a broken display look live).
public protocol SimStreamFramePresenting: Sendable {
    func applyConfig(_ config: SimStreamConfig) async
    func present(
        _ sampleBuffer: sending CMSampleBuffer, sequence: UInt64, isKeyframe: Bool
    ) async -> Bool
    func reset() async
}

public enum SimStreamViewerEngineError: Error, Equatable, Sendable {
    /// The host sent a viewer-to-host message type.
    case peerSentViewerMessage
    /// A frame arrived before any config.
    case frameBeforeConfig
    /// Six consecutive frames failed to display even after a keyframe request.
    case displayRejectedFrames
}

public enum SimStreamViewerEvent: Sendable {
    case configured(SimStreamConfig)
    case framePresented(sequence: UInt64)
    case hostState(SimStreamStateUpdate)
    /// The lane ended. `clean` distinguishes a host-side finish from a
    /// transport failure; the lifecycle machine retries either way unless a
    /// terminal host state arrived first.
    case ended(clean: Bool)
}

/// One attach attempt: opens the lane, sends `start`, then pumps messages
/// until the lane ends or the task is cancelled. Holds no state worth
/// preserving across attempts, by design: recovery is always a fresh engine.
public actor SimStreamViewerEngine {
    public typealias LaneOpener =
        @Sendable () async throws -> any MobileSimulatorStreamLaneConnection

    private let presenter: any SimStreamFramePresenting
    private let onEvent: @Sendable (SimStreamViewerEvent) -> Void
    private var maximumLongSidePixels: UInt16
    private let epoch: UInt64

    private var lane: (any MobileSimulatorStreamLaneConnection)?
    private var sampleBufferFactory: SimStreamSampleBufferFactory?
    private var outbox = SimStreamInputOutbox()
    private var isDrainingInput = false
    private var presentFailureRun = 0
    private var requestedRecoveryKeyframe = false

    public init(
        presenter: any SimStreamFramePresenting,
        maximumLongSidePixels: UInt16,
        epoch: UInt64,
        onEvent: @escaping @Sendable (SimStreamViewerEvent) -> Void
    ) {
        self.presenter = presenter
        self.maximumLongSidePixels = maximumLongSidePixels
        self.epoch = epoch
        self.onEvent = onEvent
    }

    /// Runs the attach to completion. Cancellation closes the lane.
    public func run(opener: LaneOpener) async {
        do {
            let lane = try await opener()
            self.lane = lane
            try Task.checkCancellation()
            let start = SimStreamStartRequest(
                epoch: epoch,
                maximumLongSidePixels: maximumLongSidePixels,
                codecPreferences: [.hevc, .h264]
            )
            try await lane.send(SimStreamWireCodec.encodeFramed(.start(start)))
            // Input staged while the lane was still dialing flushes now.
            drainInputIfNeeded()
            var accumulator = SimStreamFrameAccumulator()
            while let chunk = try await lane.receive() {
                guard !chunk.isEmpty else { continue }
                accumulator.append(chunk)
                while let body = try accumulator.nextMessageBody() {
                    try await handle(SimStreamWireCodec.decode(body))
                }
            }
            await closeLane()
            onEvent(.ended(clean: true))
        } catch is CancellationError {
            await closeLane()
        } catch {
            await closeLane()
            onEvent(.ended(clean: false))
        }
    }

    /// Applies a new resolution cap by re-sending `start` on the live lane.
    /// The host treats any `start` as a fresh stream begin (new encoder
    /// size, config, keyframe), so a quality change repaints in one frame
    /// without touching the lane or lifecycle.
    public func updateQuality(maximumLongSidePixels: UInt16) async {
        guard maximumLongSidePixels != self.maximumLongSidePixels else { return }
        self.maximumLongSidePixels = maximumLongSidePixels
        guard let lane else { return }
        let start = SimStreamStartRequest(
            epoch: epoch,
            maximumLongSidePixels: maximumLongSidePixels,
            codecPreferences: [.hevc, .h264]
        )
        try? await lane.send(SimStreamWireCodec.encodeFramed(.start(start)))
    }

    /// Sends `stop` and closes; used for deliberate viewer-initiated stops
    /// so the host tears down promptly instead of on lane error.
    public func stop() async {
        if let lane {
            try? await lane.send(SimStreamWireCodec.encodeFramed(.stop))
        }
        await closeLane()
    }

    private func closeLane() async {
        let lane = lane
        self.lane = nil
        await lane?.close()
    }

    // MARK: - Inbound

    private func handle(_ message: SimStreamMessage) async throws {
        switch message {
        case .config(let config):
            sampleBufferFactory = try SimStreamSampleBufferFactory(config: config)
            presentFailureRun = 0
            requestedRecoveryKeyframe = false
            await presenter.applyConfig(config)
            onEvent(.configured(config))
        case .frame(let frame):
            try await present(frame)
        case .state(let update):
            onEvent(.hostState(update))
        case .start, .ack, .input, .keyframeRequest, .stop:
            // Viewer-to-host messages arriving at the viewer mean the peer
            // is confused; fail closed and let the lifecycle rebuild.
            throw SimStreamViewerEngineError.peerSentViewerMessage
        }
    }

    private func present(_ frame: SimStreamFrame) async throws {
        guard let sampleBufferFactory else {
            // Frames before config violate the protocol ordering.
            throw SimStreamViewerEngineError.frameBeforeConfig
        }
        let isKeyframe = frame.flags.contains(.keyframe)
        var presented = false
        do {
            let sampleBuffer = try sampleBufferFactory.makeSampleBuffer(from: frame)
            presented = await presenter.present(
                sampleBuffer, sequence: frame.sequence, isKeyframe: isKeyframe)
        } catch {
            presented = false
        }
        if presented {
            presentFailureRun = 0
            requestedRecoveryKeyframe = false
            if let lane {
                let receipt = UInt64(
                    Double(DispatchTime.now().uptimeNanoseconds) / 1_000)
                try await lane.send(
                    SimStreamWireCodec.encodeFramed(
                        .ack(
                            SimStreamAck(
                                sequence: frame.sequence,
                                receiptMicroseconds: receipt))))
            }
            onEvent(.framePresented(sequence: frame.sequence))
            return
        }
        presentFailureRun += 1
        // Recovery ladder: one keyframe request, then declare the stream
        // wedged so the lifecycle machine rebuilds from scratch. Never ack a
        // frame that did not display.
        if presentFailureRun >= 6 {
            throw SimStreamViewerEngineError.displayRejectedFrames
        }
        if presentFailureRun >= 3, !requestedRecoveryKeyframe, let lane {
            requestedRecoveryKeyframe = true
            await presenter.reset()
            try await lane.send(SimStreamWireCodec.encodeFramed(.keyframeRequest))
        }
    }

    // MARK: - Input

    /// Enqueues one input event and flushes immediately. Ordering is
    /// preserved end to end; only intermediate touch moves coalesce.
    public func send(_ event: SimStreamInputEvent) {
        outbox.enqueue(event)
        drainInputIfNeeded()
    }

    private func drainInputIfNeeded() {
        guard !isDrainingInput, lane != nil else { return }
        isDrainingInput = true
        Task { await drainInput() }
    }

    private func drainInput() async {
        defer { isDrainingInput = false }
        while let lane, let batch = outbox.drainBatch() {
            do {
                try await lane.send(SimStreamWireCodec.encodeFramed(.input(batch)))
            } catch {
                // The read loop surfaces the lane failure; pending input for
                // a dead lane is discarded rather than replayed into a
                // future session where it would be stale.
                outbox.removeAll()
                return
            }
        }
    }
}
