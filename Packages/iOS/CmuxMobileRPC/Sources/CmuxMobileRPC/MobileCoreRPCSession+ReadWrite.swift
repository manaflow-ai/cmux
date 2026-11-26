import CMUXMobileCore
import Foundation

// MobileCoreRPCSession's transport loops: the write loop and the read loop.
extension MobileCoreRPCSession {
    func writeLoop(
        transport: any CmxByteTransport,
        connectionID: UUID,
        frames: AsyncStream<PendingWrite>
    ) async {
        let repairing = transport as? any CmxByteTransportControlStreamRepairing
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(write) else {
                continue
            }
            let sendTask = Task<UInt64?, any Error> {
                if let repairing {
                    return try await repairing.sendReportingControlStreamGeneration(write.frame)
                }
                try await transport.send(write.frame)
                return nil
            }
            activeWrite = ActiveWrite(
                connectionID: connectionID,
                requestID: write.requestID,
                task: sendTask
            )
            do {
                let generation = try await sendTask.value
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
                if let generation, installedConnectionID == connectionID {
                    noteControlFrameWritten(write, generation: generation)
                }
            } catch {
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .connectionClosed
                )
                return
            }
        }
    }

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
            guard !Task.isCancelled,
                  installedConnectionID == connectionID else {
                return
            }
            // Enforce size per decoded frame. A chunk can finish one valid
            // maximum-size frame and also contain bytes from the next frame.
            inboundDeliveryCount &+= 1
            // The lane just proved it still carries bytes.
            silentTimeoutStreak = 0
            buffer.append(chunk)
            do {
                while !Task.isCancelled, installedConnectionID == connectionID {
                    let frames = try MobileSyncFrameCodec.decodeFrames(
                        from: &buffer,
                        maximumDecodedFrameCount: Self.maximumDecodedFrameCountPerRead
                    )
                    for frame in frames { dispatch(frame: frame) }
                    guard frames.count == Self.maximumDecodedFrameCountPerRead else { break }
                    await Task.yield()
                }
            } catch {
                await tearDownIfInstalled(connectionID: connectionID, error: .invalidResponse)
                return
            }
        }
    }
}
