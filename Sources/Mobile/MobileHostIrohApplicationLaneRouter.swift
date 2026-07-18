import CmuxIrohTransport
import Foundation
import OSLog

private let mobileHostIrohLaneLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-iroh-lanes"
)

/// Registration seam for the future artifact-preview consumer.
///
/// The central router remains the sole QUIC accept owner. A registered feature
/// receives only lanes admitted for the authenticated same-account peer and
/// must return `true` only after taking complete ownership of both stream halves.
protocol MobileHostIrohArtifactLaneHandling: Sendable {
    func handleArtifactLane(
        resourceID: CmxIrohResourceID,
        offset: UInt64,
        stream: CmxIrohBidirectionalStream,
        peer: CmxIrohAdmittedPeer
    ) async -> Bool
}

/// Safe production default until artifact preview installs a resource owner.
struct MobileHostIrohRejectingArtifactLaneHandler: MobileHostIrohArtifactLaneHandling {
    func handleArtifactLane(
        resourceID: CmxIrohResourceID,
        offset: UInt64,
        stream: CmxIrohBidirectionalStream,
        peer: CmxIrohAdmittedPeer
    ) async -> Bool {
        false
    }
}

/// Sole Mac-side accept owner for post-admission Iroh application streams.
///
/// Terminal lanes route a validated surface UUID to sequence-framed PTY output
/// and bounded, length-prefixed UTF-8 input. Artifact lanes are delegated through one
/// registration seam and otherwise reset. Every task is owned by this admitted
/// session and cancelled when the control connection or runtime generation ends.
actor MobileHostIrohApplicationLaneRouter {
    static let maximumConcurrentLaneCount: UInt64 = 4

    enum InputFrameError: Error, Equatable {
        case invalidLength
        case invalidUTF8
    }

    private enum ErrorCode {
        static let unsupportedResource: UInt64 = 2
        static let quotaExceeded: UInt64 = 3
        static let cursorGap: UInt64 = 4
        static let invalidInput: UInt64 = 5
    }

    private static let maximumInputFrameByteCount = 16 * 1_024
    private static let maximumInputBufferByteCount = maximumInputFrameByteCount + 4

    private let session: CmxIrohAdmittedServerSession
    private let artifactHandler: any MobileHostIrohArtifactLaneHandling
    private let terminalDataPlane: any MobileTerminalDataPlane
    private var laneTasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        session: CmxIrohAdmittedServerSession,
        terminalDataPlane: any MobileTerminalDataPlane,
        artifactHandler: any MobileHostIrohArtifactLaneHandling = MobileHostIrohRejectingArtifactLaneHandler()
    ) {
        self.session = session
        self.terminalDataPlane = terminalDataPlane
        self.artifactHandler = artifactHandler
    }

    func run(
        isCurrent: @escaping CmxIrohHostRuntime.CurrentGeneration
    ) async {
        while !stopped, !Task.isCancelled, await isCurrent() {
            do {
                let accepted = try await session.acceptBidirectionalLane()
                guard !stopped, !Task.isCancelled, await isCurrent() else {
                    await Self.reject(accepted.stream, errorCode: ErrorCode.unsupportedResource)
                    break
                }
                await start(accepted.lane, stream: accepted.stream)
            } catch is CancellationError {
                break
            } catch CmxIrohServerSessionError.applicationLaneRejected {
                if !stopped, !Task.isCancelled {
                    mobileHostIrohLaneLog.info(
                        "Rejected one invalid Iroh application lane; session remains active"
                    )
                }
                continue
            } catch {
                if !stopped, !Task.isCancelled {
                    mobileHostIrohLaneLog.error(
                        "Iroh application lane accept failed: \(String(describing: error), privacy: .private)"
                    )
                }
                break
            }
        }
        await stop()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        let tasks = Array(laneTasks.values)
        laneTasks.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func start(
        _ lane: CmxIrohLane,
        stream: CmxIrohBidirectionalStream
    ) async {
        guard laneTasks.count < Int(Self.maximumConcurrentLaneCount) else {
            await Self.reject(stream, errorCode: ErrorCode.quotaExceeded)
            return
        }
        let id = UUID()
        let peer = session.peer
        let artifactHandler = artifactHandler
        let terminalDataPlane = terminalDataPlane
        let task = Task { [weak self] in
            switch lane {
            case let .terminal(resourceID, cursor):
                await Self.handleTerminalLane(
                    resourceID: resourceID,
                    cursor: cursor,
                    stream: stream,
                    terminalDataPlane: terminalDataPlane
                )
            case let .artifact(resourceID, offset):
                let didTakeOwnership = await artifactHandler.handleArtifactLane(
                    resourceID: resourceID,
                    offset: offset,
                    stream: stream,
                    peer: peer
                )
                if !didTakeOwnership {
                    await Self.reject(stream, errorCode: ErrorCode.unsupportedResource)
                }
            case .control, .serverEvents:
                await Self.reject(stream, errorCode: ErrorCode.unsupportedResource)
            }
            await self?.laneDidFinish(id)
        }
        laneTasks[id] = task
    }

    private func laneDidFinish(_ id: UUID) {
        laneTasks[id] = nil
    }

    private nonisolated static func handleTerminalLane(
        resourceID: CmxIrohResourceID,
        cursor: UInt64?,
        stream: CmxIrohBidirectionalStream,
        terminalDataPlane: any MobileTerminalDataPlane
    ) async {
        guard let surfaceID = terminalSurfaceID(resourceID) else {
            await reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }
        let lane: any MobileTerminalDataPlaneLane
        do {
            lane = try await terminalDataPlane.openLane(
                surfaceID: surfaceID,
                cursor: cursor
            )
        } catch MobileTerminalDataPlaneError.cursorGap {
            await reject(stream, errorCode: ErrorCode.cursorGap)
            return
        } catch {
            await reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await sendTerminalOutput(
                    lane: lane,
                    stream: stream
                )
                return true
            }
            group.addTask {
                await receiveTerminalInput(
                    lane: lane,
                    stream: stream
                )
            }
            if await group.next() == true {
                group.cancelAll()
            } else {
                _ = await group.next()
            }
            group.cancelAll()
        }
        await lane.close()
        await stream.receiveStream.stop(errorCode: 0)
    }

    /// Returns `true` when the complete lane should close. A clean input-side
    /// finish returns false because the client may intentionally retain an
    /// output-only terminal stream.
    private nonisolated static func receiveTerminalInput(
        lane: any MobileTerminalDataPlaneLane,
        stream: CmxIrohBidirectionalStream
    ) async -> Bool {
        var buffer = Data()
        do {
            while !Task.isCancelled,
                  let data = try await stream.receiveStream.receive(
                      maximumByteCount: max(1, maximumInputBufferByteCount - buffer.count)
                  ) {
                guard !data.isEmpty else { continue }
                buffer.append(data)
                guard buffer.count <= maximumInputBufferByteCount else {
                    await reject(stream, errorCode: ErrorCode.invalidInput)
                    return true
                }
                for input in try decodeTerminalInputFrames(from: &buffer) {
                    do {
                        try await lane.sendInput(input)
                    } catch {
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

    private nonisolated static func sendTerminalOutput(
        lane: any MobileTerminalDataPlaneLane,
        stream: CmxIrohBidirectionalStream
    ) async {
        do {
            let frames = try await lane.frames()
            for try await frame in frames {
                try Task.checkCancellation()
                switch frame.kind {
                case .replay:
                    guard frame.data.count <=
                            CmxIrohTerminalOutputEnvelope.maximumPayloadByteCount else {
                        throw MobileTerminalDataPlaneError.streamOverflow
                    }
                    let envelope = try CmxIrohTerminalOutputEnvelope(
                        kind: .replay,
                        retainedBaseSequence: frame.retainedBaseSequence,
                        sequence: frame.sequence,
                        currentSequence: frame.currentSequence,
                        payload: frame.data
                    )
                    try await stream.sendStream.send(
                        CmxIrohTerminalOutputEnvelopeCodec().encode(envelope)
                    )
                case .chunk:
                    try await sendTerminalOutputChunks(
                        frame.data,
                        startingAt: frame.sequence,
                        stream: stream
                    )
                }
            }
            try await stream.sendStream.finish()
        } catch is CancellationError {
            await stream.sendStream.reset(errorCode: 0)
        } catch {
            await stream.sendStream.reset(errorCode: ErrorCode.cursorGap)
        }
    }

    private nonisolated static func sendTerminalOutputChunks(
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
            let payload = Data(data[offset ..< (offset + payloadByteCount)])
            let sequence = startingSequence + UInt64(offset)
            let currentSequence = sequence + UInt64(payloadByteCount)
            let envelope = try CmxIrohTerminalOutputEnvelope(
                kind: .chunk,
                retainedBaseSequence: sequence,
                sequence: sequence,
                currentSequence: currentSequence,
                payload: payload
            )
            try await stream.sendStream.send(codec.encode(envelope))
            offset += payloadByteCount
        }
    }

    private nonisolated static func terminalSurfaceID(
        _ resourceID: CmxIrohResourceID
    ) -> UUID? {
        let value = resourceID.value
        let rawID = value.hasPrefix("terminal:")
            ? String(value.dropFirst("terminal:".count))
            : value
        return UUID(uuidString: rawID)
    }

    nonisolated static func decodeTerminalInputFrames(
        from buffer: inout Data
    ) throws -> [String] {
        var frames: [String] = []
        while buffer.count >= 4 {
            let frameLength = buffer.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard frameLength > 0,
                  frameLength <= UInt32(maximumInputFrameByteCount) else {
                throw InputFrameError.invalidLength
            }
            let totalLength = 4 + Int(frameLength)
            guard buffer.count >= totalLength else { break }
            let payload = Data(buffer.dropFirst(4).prefix(Int(frameLength)))
            guard let input = String(data: payload, encoding: .utf8) else {
                throw InputFrameError.invalidUTF8
            }
            buffer.removeFirst(totalLength)
            frames.append(input)
        }
        return frames
    }

    private nonisolated static func reject(
        _ stream: CmxIrohBidirectionalStream,
        errorCode: UInt64
    ) async {
        await stream.sendStream.reset(errorCode: errorCode)
        await stream.receiveStream.stop(errorCode: errorCode)
    }
}
