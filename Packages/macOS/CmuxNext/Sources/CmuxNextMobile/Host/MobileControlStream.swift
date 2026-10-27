import CMUXMobileCore
import Foundation

/// One admitted phone's control stream: shipped-iOS RPC requests in `MobileSyncFrameCodec` frames, one
/// answer frame each, in arrival order, then the phone's session closes. Bytes that are not a frame (a
/// length past the codec's limit) end this phone's stream and session only, as Chrome ends only the
/// renderer that sent a bad message (content/browser/bad_message.cc, ReceivedBadMessage); every other
/// phone keeps its own connection and session.
struct MobileControlStream: Sendable {
    let transport: any CmxByteTransport
    let session: MobileCompatSession

    /// Serves until the phone closes the stream or sends a bad frame, then closes the session. Returns
    /// what ended it: nil when the phone closed the stream, else the read, write or framing error.
    func run() async -> (any Error)? {
        var ended: (any Error)?
        do {
            try await serve()
        } catch {
            ended = error
        }
        await session.close()
        return ended
    }

    private func serve() async throws {
        var buffer = Data()
        while let chunk = try await transport.receive() {
            buffer.append(chunk)
            var frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            while !frames.isEmpty {
                for frame in frames {
                    // Requests run in arrival order: input stays ordered.
                    let response = await session.handle(frame: frame)
                    try await transport.send(MobileSyncFrameCodec.encodeFrame(response))
                }
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            }
        }
    }
}
