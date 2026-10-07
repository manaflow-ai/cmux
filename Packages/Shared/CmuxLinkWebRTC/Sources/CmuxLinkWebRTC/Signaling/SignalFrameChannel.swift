public import CmuxLinkSignaling
public import CmuxMobileWire
import Foundation

/// A `SignalingChannel` over raw `signal` frames, for a side that owns its
/// control socket itself: the Mac host (B5's `HostControlUplink` hands
/// relayed frames to `receive`, which matches its `SignalingSink`, and
/// `send` writes `signal` frames on the host socket).
public final class SignalFrameChannel: SignalingChannel {
    public let incoming: AsyncStream<SignalMessage>
    private let sink: AsyncStream<SignalMessage>.Continuation
    private let codec: SignalFrameCodec
    private let sendFrame: @Sendable (SignalFrame) async throws -> Void

    public init(codec: SignalFrameCodec = SignalFrameCodec(), send: @escaping @Sendable (SignalFrame) async throws -> Void) {
        self.codec = codec
        sendFrame = send
        (incoming, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .unbounded)
    }

    /// A frame the relay delivered to this install.
    public func receive(_ signal: SignalFrame) async {
        if let message = codec.message(from: signal) { sink.yield(message) }
    }

    public func send(_ message: SignalMessage) async throws {
        var frame = codec.frame(for: message)
        frame.from = nil
        try await sendFrame(frame)
    }

    /// Ends `incoming` (the socket is gone for good).
    public func finish() {
        sink.finish()
    }
}
