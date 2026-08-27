import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Serves one terminal lane over irx: bounded replay from the byte tee at
/// the requested cursor, then live chunks, with length-prefixed input frames
/// flowing upstream. The envelope format and error codes are the proven
/// legacy contract (`CmxIrohTerminalOutputEnvelope`); only the transport
/// beneath is irx.
enum MobileHostIrxTerminalLaneServer {
    private enum ErrorCode {
        static let unsupportedResource: UInt64 = 2
        static let cursorGap: UInt64 = 4
        static let invalidInput: UInt64 = 5
    }

    private static let maximumInputFrameByteCount = 16 * 1_024
    private static let maximumInputBufferByteCount = 64 * 1_024

    static func serve(
        resourceID: String,
        cursor: UInt64?,
        stream: CmxIrohBidirectionalStream,
        journal: IrxJournal
    ) async {
        guard let surfaceID = terminalSurfaceID(resourceID),
            await MainActor.run(body: {
                GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil
            })
        else {
            journal.record(
                "host-terminal", "lane-rejected",
                ["resource": resourceID, "code": "unsupported-resource"]
            )
            await reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }
        journal.record(
            "host-terminal", "lane-serving",
            ["surface": surfaceID.uuidString, "cursor": cursor.map(String.init) ?? "-"]
        )
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await sendOutput(surfaceID: surfaceID, cursor: cursor, stream: stream, journal: journal)
                return true
            }
            group.addTask {
                await receiveInput(surfaceID: surfaceID, stream: stream)
            }
            if await group.next() == true {
                group.cancelAll()
            } else {
                _ = await group.next()
            }
            group.cancelAll()
        }
        await stream.receiveStream.stop(errorCode: 0)
        journal.record("host-terminal", "lane-closed", ["surface": surfaceID.uuidString])
    }

    private static func sendOutput(
        surfaceID: UUID,
        cursor: UInt64?,
        stream: CmxIrohBidirectionalStream,
        journal: IrxJournal
    ) async {
        let updates = await MainActor.run {
            guard GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil
            else {
                return Optional<AsyncStream<MobileTerminalByteTee.OutputChunk>>.none
            }
            return MobileTerminalByteTee.shared.outputUpdates(surfaceID: surfaceID)
        }
        guard let updates else {
            await reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }
        let replay = await MainActor.run {
            MobileTerminalByteTee.shared.replayState(surfaceID: surfaceID)
        }
        let currentSequence = replay?.seq ?? 0
        let replayData = replay?.data ?? Data()
        let replayStart = currentSequence - UInt64(replayData.count)
        let requestedSequence = cursor ?? replayStart
        guard requestedSequence >= replayStart, requestedSequence <= currentSequence else {
            journal.record(
                "host-terminal", "cursor-gap",
                [
                    "requested": String(requestedSequence),
                    "retained_base": String(replayStart),
                    "current": String(currentSequence),
                ]
            )
            await reject(stream, errorCode: ErrorCode.cursorGap)
            return
        }
        var nextSequence = requestedSequence
        do {
            let replayOffset = Int(requestedSequence - replayStart)
            let replayPayload = Data(replayData.dropFirst(replayOffset))
            let replayEnvelope = try CmxIrohTerminalOutputEnvelope(
                kind: .replay,
                retainedBaseSequence: replayStart,
                sequence: requestedSequence,
                currentSequence: currentSequence,
                payload: replayPayload
            )
            try await stream.sendStream.send(
                CmxIrohTerminalOutputEnvelopeCodec().encode(replayEnvelope)
            )
            nextSequence = currentSequence
            for await chunk in updates {
                try Task.checkCancellation()
                let chunkEnd = chunk.sequence + UInt64(chunk.data.count)
                if chunkEnd <= nextSequence { continue }
                guard chunk.sequence <= nextSequence else {
                    await reject(stream, errorCode: ErrorCode.cursorGap)
                    return
                }
                let offset = Int(nextSequence - chunk.sequence)
                try await sendChunks(
                    Data(chunk.data.dropFirst(offset)),
                    startingAt: nextSequence,
                    stream: stream
                )
                nextSequence = chunkEnd
            }
            try await stream.sendStream.finish()
        } catch is CancellationError {
            await stream.sendStream.reset(errorCode: 0)
        } catch {
            await stream.sendStream.reset(errorCode: ErrorCode.cursorGap)
        }
    }

    private static func sendChunks(
        _ data: Data,
        startingAt startingSequence: UInt64,
        stream: CmxIrohBidirectionalStream
    ) async throws {
        let codec = CmxIrohTerminalOutputEnvelopeCodec()
        var offset = 0
        while offset < data.count {
            let payloadByteCount = min(
                CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount,
                data.count - offset
            )
            let payload = Data(data[offset..<(offset + payloadByteCount)])
            let sequence = startingSequence + UInt64(offset)
            let envelope = try CmxIrohTerminalOutputEnvelope(
                kind: .chunk,
                retainedBaseSequence: sequence,
                sequence: sequence,
                currentSequence: sequence + UInt64(payloadByteCount),
                payload: payload
            )
            try await stream.sendStream.send(codec.encode(envelope))
            offset += payloadByteCount
        }
    }

    /// Returns true when the whole lane should close (an input error), false
    /// on a clean input-side finish (output-only lanes stay open).
    private static func receiveInput(
        surfaceID: UUID,
        stream: CmxIrohBidirectionalStream
    ) async -> Bool {
        var buffer = Data()
        do {
            while !Task.isCancelled,
                let data = try await stream.receiveStream.receive(
                    maximumByteCount: max(1, maximumInputBufferByteCount - buffer.count)
                )
            {
                guard !data.isEmpty else { continue }
                buffer.append(data)
                guard buffer.count <= maximumInputBufferByteCount else {
                    await reject(stream, errorCode: ErrorCode.invalidInput)
                    return true
                }
                for input in try MobileHostIrohApplicationLaneRouter
                    .decodeTerminalInputFrames(from: &buffer)
                {
                    guard await deliverInput(input, surfaceID: surfaceID) else {
                        await reject(stream, errorCode: ErrorCode.invalidInput)
                        return true
                    }
                }
            }
            if !buffer.isEmpty {
                await reject(stream, errorCode: ErrorCode.invalidInput)
                return true
            }
            return false
        } catch is CancellationError {
            return true
        } catch {
            await reject(stream, errorCode: ErrorCode.invalidInput)
            return true
        }
    }

    private static func deliverInput(_ input: String, surfaceID: UUID) async -> Bool {
        await MainActor.run {
            guard
                let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(
                    id: surfaceID)
            else { return false }
            switch surface.sendInputResult(input) {
            case .sent:
                surface.forceRefresh(reason: "mobileHost.irxTerminalLaneInput")
                return true
            case .queued:
                return true
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    private static func terminalSurfaceID(_ resourceID: String) -> UUID? {
        let rawID = resourceID.hasPrefix("terminal:")
            ? String(resourceID.dropFirst("terminal:".count))
            : resourceID
        return UUID(uuidString: rawID)
    }

    private static func reject(
        _ stream: CmxIrohBidirectionalStream,
        errorCode: UInt64
    ) async {
        await stream.sendStream.reset(errorCode: errorCode)
        await stream.receiveStream.stop(errorCode: errorCode)
    }
}
