public import CoreGraphics
import Foundation
import CmuxNextCompat

// Development builds only: the pane is not exposed in Release until the
// overlay link token authenticates hello claims (RemoteViewAvailability).
#if DEBUG
/// A host stand-in for demos and tests: paints a synthetic desktop, encodes
/// it with VideoToolbox like the real host, and streams the access units.
/// Damage driven like the host (RD3): a frame is produced only when
/// something changes (`damage()`, a pointer move from `MockRemoteInputSink`,
/// or a keyframe request), so a static mock costs nothing.
public nonisolated final class MockRemoteStreamSource: RemoteViewStreamSource {
    public let codec: RemoteVideoCodec
    public let width: Int
    public let height: Int
    private let state: Mutex<State>
    /// Nil when VideoToolbox has no encoder for `codec` here.
    private let encoder: MockFrameEncoder?

    private struct State {
        var units: AsyncStream<RemoteAccessUnit>.Continuation?
        var statuses: AsyncStream<RemoteViewStatus>.Continuation?
        var cursors: AsyncStream<RemoteCursorState>.Continuation?
        var status: RemoteViewStatus
        var scene = SyntheticFramePainter.Scene(counter: 0, pointer: CGPoint(x: 200, y: 200))
        var nextFrame: UInt32 = 0
        var forceKeyframe = true
        var keyframeRequests = 0
        var encoded = 0
    }

    /// `status` is the first value `statusUpdates()` reports.
    public init(
        codec: RemoteVideoCodec = .h264, width: Int = 1280, height: Int = 800,
        status: RemoteViewStatus = RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming)
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        encoder = MockFrameEncoder(codec: codec, width: width, height: height)
        state = Mutex(State(status: status))
    }

    /// False when VideoToolbox has no encoder for `codec` here.
    public var canEncode: Bool { encoder != nil }

    public func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
        let previous = state.withLock { state in
            defer { state.units = continuation }
            return state.units
        }
        previous?.finish()
        return stream
    }

    public func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let (previous, current) = state.withLock { state in
            defer { state.statuses = continuation }
            return (state.statuses, state.status)
        }
        previous?.finish()
        continuation.yield(current)
        return stream
    }

    public func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteCursorState.self, bufferingPolicy: .bufferingNewest(1))
        let previous = state.withLock { state in
            defer { state.cursors = continuation }
            return state.cursors
        }
        previous?.finish()
        return stream
    }

    public func requestKeyframe() {
        state.withLock {
            $0.forceKeyframe = true
            $0.keyframeRequests += 1
        }
        damage()
    }

    public var keyframeRequests: Int { state.withLock { $0.keyframeRequests } }

    /// Reports a new status (path change, consent, end of session).
    public func setStatus(_ status: RemoteViewStatus) {
        let continuation = state.withLock { state in
            state.status = status
            return state.statuses
        }
        continuation?.yield(status)
    }

    /// Moves the synthetic pointer (frame pixels), reports the remote
    /// cursor, and paints a frame.
    public func movePointer(to point: CGPoint) {
        let continuation = state.withLock { state in
            state.scene.pointer = point
            return state.cursors
        }
        continuation?.yield(RemoteCursorState(position: point, visible: true))
        damage()
    }

    /// Paints and encodes the next frame (the counter advances).
    /// The encoder numbers each frame when it paints it, so frames stream in order whatever
    /// order these tasks reach it in.
    public func damage() {
        guard let encoder else { return }
        Task { [self] in await encoder.encodeNext(for: self) }
    }

    /// Ends the session: every stream finishes after `status`.
    public func end(_ reason: RemoteSessionEnd) {
        setStatus(RemoteViewStatus(path: state.withLock { $0.status.path }, state: .ended(reason)))
        let continuations = state.withLock { ($0.units, $0.cursors) }
        continuations.0?.finish()
        continuations.1?.finish()
    }

    /// The next frame's scene, number and whether it must be a keyframe; the counter advances.
    fileprivate func takeNextFrame() -> (scene: SyntheticFramePainter.Scene, frame: UInt32, keyframe: Bool) {
        state.withLock { state in
            state.scene.counter &+= 1
            defer {
                state.nextFrame &+= 1
                state.forceKeyframe = false
            }
            return (state.scene, state.nextFrame, state.forceKeyframe)
        }
    }

    /// Streams one encoded frame (called on a VideoToolbox output thread).
    fileprivate func emit(_ output: (data: Data, keyframe: Bool), frame: UInt32, capturedMicros: UInt64) {
        let unit = RemoteAccessUnit(
            frame: frame, flags: output.keyframe ? .keyframe : [], tCaptureMicros: capturedMicros,
            data: output.data, codec: codec)
        let continuation = state.withLock { state in
            state.encoded += 1
            return state.units
        }
        continuation?.yield(unit)
    }
}

/// The mock host's encoder, confined to its own serial queue: paint, encode and the VideoToolbox
/// flush (which waits for the encoder's output) block that queue, never a cooperative pool
/// thread, and no lock is held across them.
private actor MockFrameEncoder {
    private nonisolated let queue = DispatchSerialQueue(label: "cmux.remote-view.mock-host", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let encoder: SyntheticFrameEncoder

    init?(codec: RemoteVideoCodec, width: Int, height: Int) {
        guard let encoder = SyntheticFrameEncoder(codec: codec, width: width, height: height) else { return nil }
        self.encoder = encoder
    }

    /// Paints and encodes `source`'s next frame; its access unit goes out on `source`'s stream.
    func encodeNext(for source: MockRemoteStreamSource) {
        guard let buffer = encoder.makeBuffer() else { return }
        let next = source.takeNextFrame()
        let captured = DispatchTime.now().uptimeNanoseconds / 1000
        SyntheticFramePainter.paint(next.scene, into: buffer)
        let frame = next.frame
        encoder.encode(buffer, index: Int(frame), forceKeyframe: next.keyframe) { [weak source] output in
            guard let output else { return }
            source?.emit(output, frame: frame, capturedMicros: captured)
        }
        encoder.flush()
    }
}
/// The mock host accepts every granted upstream request at once (the
/// status reports it active), so the pane's share buttons, indicator and
/// Stop work without a real host. It captures nothing.
extension MockRemoteStreamSource: RemoteUpstreamControl {
    /// The status the mock reports now.
    public var currentStatus: RemoteViewStatus { state.withLock { $0.status } }

    public func requestUpstream(_ kind: RemoteUpstreamKind, permissionGranted: Bool) {
        updateUpstream { upstream, state in
            guard permissionGranted, upstream.offered, state == .streaming else { return }
            upstream.active.insert(kind)
        }
    }

    public func stopUpstream(_ kind: RemoteUpstreamKind) {
        updateUpstream { upstream, _ in upstream.active.remove(kind) }
    }

    public func stopAllUpstreams() {
        updateUpstream { upstream, _ in upstream.active.removeAll() }
    }

    private func updateUpstream(_ change: (inout RemoteUpstreamStatus, RemoteSessionState) -> Void) {
        let (status, continuation) = state.withLock { state in
            change(&state.status.upstream, state.status.state)
            return (state.status, state.statuses)
        }
        continuation?.yield(status)
    }
}
#endif
