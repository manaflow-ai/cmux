import Foundation

/// One raw frame from the capture side (packed BGRA).
public struct SimStreamSourceFrame: Sendable, Equatable {
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// Capture-side publication sequence (independent of wire sequence).
    public let sequence: UInt64

    public init(pixels: Data, width: Int, height: Int, bytesPerRow: Int, sequence: UInt64) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.sequence = sequence
    }
}

/// Capture seam: returns the newest stable frame newer than `sequence`,
/// or nil when nothing newer exists.
public protocol SimStreamFrameSource: Sendable {
    func copyLatestFrame(after sequence: UInt64?) async -> SimStreamSourceFrame?
}

/// Transport seam: sends one complete framed wire message.
public protocol SimStreamMessageSending: Sendable {
    func send(_ data: Data) async throws
}

/// The host-side streaming engine: latest-frame-wins, encode-on-credit.
///
/// All wire writes (config, frames, state) funnel through this actor, so the
/// send stream never sees interleaved partial messages. The pump never queues
/// an encoded frame: it encodes only when the credit gate is open and always
/// encodes the newest captured frame, so backpressure surfaces as reduced
/// frame rate, never as latency.
public actor SimStreamHostPump {
    public struct Geometry: Sendable, Equatable {
        public var displayScale: Float
        public var orientation: SimStreamOrientation

        public init(displayScale: Float, orientation: SimStreamOrientation) {
            self.displayScale = displayScale
            self.orientation = orientation
        }
    }

    private let sink: any SimStreamMessageSending
    private let now: @Sendable () -> TimeInterval
    private let onFatal: @Sendable (String) -> Void

    private var source: (any SimStreamFrameSource)?
    private var geometry = Geometry(displayScale: 2.0, orientation: .portrait)
    private var codec: SimStreamVideoCodec = .hevc
    private var maximumLongSide = 0

    private var encoder: SimStreamVideoEncoder?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private let pixelFactory = SimStreamPixelBufferFactory()

    private var gate = SimStreamCreditGate(window: 2)
    private var bitrate = SimStreamBitrateController()
    private var sendTimesBySequence: [UInt64: TimeInterval] = [:]

    private var lastCopiedSourceSequence: UInt64?
    private var needsConfig = true
    private var needsKeyframe = true
    private var consecutiveEncodeFailures = 0
    private var lastFrameSentAt: TimeInterval?
    private var streamStartedAt: TimeInterval?
    private var started = false
    private var shutDown = false

    private let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var drainTask: Task<Void, Never>?

    public init(
        sink: any SimStreamMessageSending,
        now: @escaping @Sendable () -> TimeInterval,
        onFatal: @escaping @Sendable (String) -> Void
    ) {
        self.sink = sink
        self.now = now
        self.onFatal = onFatal
        var continuation: AsyncStream<Void>.Continuation!
        self.signals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.signalContinuation = continuation
    }

    /// Wakes the drain loop. Callable from any context, including the
    /// capture ring's Darwin-notify callback.
    public nonisolated func signalFramePublished() {
        signalContinuation.yield()
    }

    // MARK: - Session control

    public func beginStream(request: SimStreamStartRequest, geometry: Geometry) {
        self.codec = request.codecPreferences.first ?? .h264
        self.maximumLongSide = Int(request.maximumLongSidePixels)
        self.geometry = geometry
        needsConfig = true
        needsKeyframe = true
        gate.resetInFlight()
        sendTimesBySequence.removeAll()
        // A restarted stream must never wait for the next capture publication
        // to show something: re-deliver the newest existing frame.
        lastCopiedSourceSequence = nil
        started = true
        streamStartedAt = now()
        // A prior stream's frame timestamp must not bypass the fresh
        // startup grace in isStalled.
        lastFrameSentAt = nil
        if drainTask == nil {
            drainTask = Task { [weak self] in
                guard let self else { return }
                for await _ in self.signals {
                    await self.drain()
                }
            }
        }
        signalContinuation.yield()
    }

    public func setSource(_ source: (any SimStreamFrameSource)?, geometry: Geometry?) {
        self.source = source
        if let geometry, geometry != self.geometry {
            self.geometry = geometry
            needsConfig = true
            needsKeyframe = true
        }
        if source != nil {
            // A replaced capture ring restarts its sequence space.
            lastCopiedSourceSequence = nil
            needsKeyframe = true
        }
        signalContinuation.yield()
    }

    public func noteAck(_ ack: SimStreamAck) async {
        gate.acknowledge(ack.sequence)
        if let sendTime = sendTimesBySequence.removeValue(forKey: ack.sequence) {
            if let updated = bitrate.recordAck(sendTime: sendTime, ackTime: now()) {
                await encoder?.setBitrate(updated)
            }
        }
        sendTimesBySequence = sendTimesBySequence.filter { $0.key > ack.sequence }
        signalContinuation.yield()
    }

    public func requestKeyframe() {
        needsKeyframe = true
        // Deliver the current frame again even when the capture side is idle:
        // the viewer is asking because it cannot decode what it has.
        lastCopiedSourceSequence = nil
        signalContinuation.yield()
    }

    public func sendState(_ update: SimStreamStateUpdate) async {
        guard !shutDown else { return }
        try? await sink.send(SimStreamWireCodec.encodeFramed(.state(update)))
    }

    /// True when the stream should be making progress but has not sent a
    /// frame recently; the session watchdog reacts by refreshing the reader
    /// and forcing a keyframe.
    public func isStalled(olderThan interval: TimeInterval) -> Bool {
        guard started, !shutDown, source != nil, gate.hasCredit else { return false }
        // Grace from the last progress marker: the most recent frame, or the
        // stream start when nothing has been sent yet.
        guard let reference = lastFrameSentAt ?? streamStartedAt else { return false }
        return now() - reference > interval
    }

    public func shutdown() async {
        await performShutdown()
    }

    private func performShutdown() async {
        guard !shutDown else { return }
        shutDown = true
        drainTask?.cancel()
        drainTask = nil
        signalContinuation.finish()
        await encoder?.invalidate()
        encoder = nil
        source = nil
    }

    // MARK: - Drain

    private func drain() async {
        while !shutDown, started, gate.hasCredit, let source {
            guard let frame = await source.copyLatestFrame(after: lastCopiedSourceSequence)
            else { return }
            lastCopiedSourceSequence = frame.sequence
            await encodeAndSend(frame)
        }
    }

    private func encodeAndSend(_ frame: SimStreamSourceFrame) async {
        do {
            let target = SimStreamPixelBufferFactory.encodeSize(
                sourceWidth: frame.width, sourceHeight: frame.height,
                maximumLongSide: maximumLongSide)
            let encoder = try await currentEncoder(width: target.width, height: target.height)
            let pixelBuffer = try pixelFactory.makePixelBuffer(
                pixels: frame.pixels,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                maximumLongSide: maximumLongSide
            )
            let timestampMicroseconds = UInt64(max(0, now()) * 1_000_000)
            let forceKeyframe = needsKeyframe || needsConfig
            let encoded = try await encoder.encode(
                pixelBuffer,
                presentationMicroseconds: timestampMicroseconds,
                forceKeyframe: forceKeyframe
            )
            if needsConfig {
                guard encoded.isKeyframe, !encoded.parameterSets.isEmpty else {
                    throw SimStreamVideoEncoderError.parameterSetExtractionFailed(-1)
                }
                let config = SimStreamConfig(
                    codec: codec,
                    pixelWidth: UInt32(target.width),
                    pixelHeight: UInt32(target.height),
                    displayScale: geometry.displayScale,
                    orientation: geometry.orientation,
                    parameterSets: encoded.parameterSets,
                    nalUnitHeaderLength: encoded.nalUnitHeaderLength
                )
                try await sink.send(SimStreamWireCodec.encodeFramed(.config(config)))
                needsConfig = false
            }
            let wireSequence = gate.consumeCredit()
            sendTimesBySequence[wireSequence] = now()
            let message = SimStreamFrame(
                sequence: wireSequence,
                flags: encoded.isKeyframe ? [.keyframe] : [],
                presentationMicroseconds: timestampMicroseconds,
                payload: encoded.data
            )
            do {
                try await sink.send(SimStreamWireCodec.encodeFramed(.frame(message)))
            } catch {
                // The frame never reached the viewer, so its credit must not
                // stay consumed (the viewer can never ack it). Self-settling
                // the sequence keeps the window honest; the session's read
                // loop surfaces the dead lane if the failure was terminal.
                gate.acknowledge(wireSequence)
                sendTimesBySequence.removeValue(forKey: wireSequence)
                needsKeyframe = true
                lastCopiedSourceSequence = frame.sequence == 0 ? nil : frame.sequence - 1
                return
            }
            lastFrameSentAt = now()
            needsKeyframe = false
            consecutiveEncodeFailures = 0
        } catch {
            consecutiveEncodeFailures += 1
            // A failed encode invalidates encoder state; recover with a
            // fresh session and keyframe rather than a poisoned delta chain.
            await encoder?.invalidate()
            encoder = nil
            encoderWidth = 0
            encoderHeight = 0
            needsConfig = true
            needsKeyframe = true
            // Re-deliver the same frame on the next wake.
            lastCopiedSourceSequence = frame.sequence == 0 ? nil : frame.sequence - 1
            if consecutiveEncodeFailures >= 3 {
                // Full shutdown, not just the flag: a fatal pump must still
                // release its encoder, drain task, and signal stream.
                await performShutdown()
                onFatal("encoding failed repeatedly: \(error)")
            }
        }
    }

    private func currentEncoder(width: Int, height: Int) async throws -> SimStreamVideoEncoder {
        if let encoder, encoderWidth == width, encoderHeight == height {
            return encoder
        }
        await encoder?.invalidate()
        let created = try SimStreamVideoEncoder(
            codec: codec,
            width: width,
            height: height,
            bitsPerSecond: bitrate.targetBitsPerSecond
        )
        encoder = created
        encoderWidth = width
        encoderHeight = height
        // A new encoder starts a new reference chain.
        needsConfig = true
        needsKeyframe = true
        return created
    }
}
