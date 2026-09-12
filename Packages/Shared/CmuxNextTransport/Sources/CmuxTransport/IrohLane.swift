import Foundation
import IrohLib

/// One lane on one QUIC stream. Single-consumer, like every lane (see
/// LaneFrames); the channel actor serializes writers so concurrent sends
/// cannot interleave bytes mid-frame.
public actor IrohLane: TransportLane {
    /// Negotiated lane name, stable for this stream's lifetime.
    public nonisolated let name: String
    let channel: IrohLaneChannel
    /// Stable token used by the owning connection to remove this lane only
    /// if the callback belongs to the currently registered stream.
    nonisolated let token: UUID
    private let onEnd: (@Sendable () async -> Void)?
    private var endNotified = false

    init(
        name: String,
        channel: IrohLaneChannel,
        token: UUID = UUID(),
        onEnd: (@Sendable () async -> Void)? = nil
    ) {
        self.name = name
        self.channel = channel
        self.token = token
        self.onEnd = onEnd
    }

    /// Sends one complete frame without interleaving concurrent writers' bytes.
    /// - Parameter frame: Envelope to encode on this lane.
    /// - Throws: An encoding or underlying stream-send error.
    public func send(_ frame: Frame) async throws {
        try await channel.sendFrame(frame)
    }

    /// Waits for the next frame and notifies the owner once when the lane ends.
    /// - Returns: A decoded frame, or nil after terminal stream end or failure.
    public func receive() async -> Frame? {
        let frame = await channel.receiveFrame()
        if frame == nil, !endNotified {
            endNotified = true
            await onEnd?()
        }
        return frame
    }

    /// Number of short writes observed while QUIC flow control applied
    /// backpressure to this lane.
    public var backpressureStalls: Int {
        get async { await channel.backpressureStalls }
    }

    func finishSend() async {
        await channel.finish()
    }
}
