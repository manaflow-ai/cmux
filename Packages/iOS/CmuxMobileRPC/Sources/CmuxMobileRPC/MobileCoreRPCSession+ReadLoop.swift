internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func readLoop(
        transport: any CmxByteTransport,
        connectionID: UUID
    ) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try await transport.receive()
            } catch {
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .connectionClosed
                )
                return
            }
            guard let chunk, !chunk.isEmpty else {
                if chunk == nil {
                    await tearDownIfInstalled(
                        connectionID: connectionID,
                        error: .connectionClosed
                    )
                    return
                }
                continue
            }
            buffer.append(chunk)
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            } catch {
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .invalidResponse
                )
                return
            }
            for frame in frames {
                dispatch(frame: frame)
            }
        }
    }
}
