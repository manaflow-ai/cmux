import CMUXMobileCore
import CmuxAgentChat
import CmuxPeerTransport
import Darwin
import Dispatch
import Foundation

/// Registration seam for the artifact-preview consumer.
///
/// The central router remains the sole lane consumer. A registered feature
/// receives only lanes admitted for the authenticated same-account peer and
/// must return `true` only after taking complete ownership of the stream.
protocol MobileHostPeerArtifactLaneHandling: Sendable {
    func handleArtifactLane(
        resourceID: String,
        offset: UInt64,
        stream: any MobileHostPeerArtifactStreamWriting,
        peer: MobileHostPeerAdmission
    ) async -> Bool
}

/// Safe fallback for hosts that do not install an artifact resource owner.
struct MobileHostPeerRejectingArtifactLaneHandler: MobileHostPeerArtifactLaneHandling {
    func handleArtifactLane(
        resourceID: String,
        offset: UInt64,
        stream: any MobileHostPeerArtifactStreamWriting,
        peer: MobileHostPeerAdmission
    ) async -> Bool {
        false
    }
}

/// Separate credits prevent terminal fan-out from starving one artifact lane.
struct MobileHostPeerApplicationLaneQuota {
    enum LaneClass {
        case terminal
        case artifact
    }

    static let maximumTerminalCount = 4
    static let maximumArtifactCount = 1

    private var terminalIDs: Set<UUID> = []
    private var artifactIDs: Set<UUID> = []

    var terminalCount: Int { terminalIDs.count }
    var artifactCount: Int { artifactIDs.count }

    mutating func reserve(_ id: UUID, laneClass: LaneClass) -> Bool {
        switch laneClass {
        case .terminal:
            guard terminalIDs.count < Self.maximumTerminalCount else { return false }
            terminalIDs.insert(id)
        case .artifact:
            guard artifactIDs.count < Self.maximumArtifactCount else { return false }
            artifactIDs.insert(id)
        }
        return true
    }

    mutating func release(_ id: UUID) {
        terminalIDs.remove(id)
        artifactIDs.remove(id)
    }
}

/// Sole Mac-side consumer of post-admission peer application lanes.
///
/// Terminal lanes route a validated surface UUID to sequence-framed PTY output
/// and bounded, length-prefixed UTF-8 input. Artifact lanes are delegated
/// through one registration seam and otherwise reset. Every task is owned by
/// this admitted session and cancelled when the control connection or runtime
/// generation ends.
actor MobileHostPeerLaneRouter {
    static let maximumConcurrentTerminalLaneCount =
        UInt64(MobileHostPeerApplicationLaneQuota.maximumTerminalCount)
    static let maximumConcurrentArtifactLaneCount =
        UInt64(MobileHostPeerApplicationLaneQuota.maximumArtifactCount)
    static let maximumConcurrentLaneCount =
        maximumConcurrentTerminalLaneCount + maximumConcurrentArtifactLaneCount

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

    private let session: PeerHostSession
    private let peer: MobileHostPeerAdmission
    private let artifactHandler: any MobileHostPeerArtifactLaneHandling
    private var laneTasks: [UUID: Task<Void, Never>] = [:]
    private var laneQuota = MobileHostPeerApplicationLaneQuota()
    private var stopped = false

    init(
        session: PeerHostSession,
        peer: MobileHostPeerAdmission,
        artifactHandler: any MobileHostPeerArtifactLaneHandling = MobileHostPeerRejectingArtifactLaneHandler()
    ) {
        self.session = session
        self.peer = peer
        self.artifactHandler = artifactHandler
    }

    /// Consumes the session's application-lane stream until the connection
    /// closes, the router stops, or the runtime generation ends. Malformed
    /// lanes are already reset inside `PeerHostSession.applicationLanes()`.
    func run(isCurrent: @escaping @Sendable () async -> Bool) async {
        let lanes = session.applicationLanes()
        for await lane in lanes {
            guard !stopped, !Task.isCancelled, await isCurrent() else {
                await Self.reject(
                    Self.stream(of: lane),
                    errorCode: ErrorCode.unsupportedResource
                )
                break
            }
            start(lane)
        }
        await stop()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        let tasks = Array(laneTasks.values)
        laneTasks.removeAll()
        laneQuota = MobileHostPeerApplicationLaneQuota()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private static func stream(of lane: PeerInboundApplicationLane) -> PeerByteStream {
        switch lane {
        case let .terminal(_, _, _, stream):
            stream
        case let .artifact(_, _, _, stream):
            stream
        }
    }

    private func start(_ lane: PeerInboundApplicationLane) {
        let laneClass: MobileHostPeerApplicationLaneQuota.LaneClass
        switch lane {
        case .terminal:
            laneClass = .terminal
        case .artifact:
            laneClass = .artifact
        }
        let id = UUID()
        let stream = Self.stream(of: lane)
        guard laneQuota.reserve(id, laneClass: laneClass) else {
            let task = Task {
                await Self.reject(stream, errorCode: ErrorCode.quotaExceeded)
            }
            laneTasks[id] = task
            Task { [weak self] in
                await task.value
                await self?.laneDidFinish(id)
            }
            return
        }
        let peer = peer
        let artifactHandler = artifactHandler
        let task = Task { [weak self] in
            switch lane {
            case let .terminal(resourceID, cursor, initialBytes, stream):
                await Self.handleTerminalLane(
                    resourceID: resourceID,
                    cursor: cursor,
                    initialInputBytes: initialBytes,
                    stream: stream
                )
            case let .artifact(resourceID, offset, _, stream):
                let didTakeOwnership = await artifactHandler.handleArtifactLane(
                    resourceID: resourceID,
                    offset: offset,
                    stream: stream,
                    peer: peer
                )
                if !didTakeOwnership {
                    await Self.reject(stream, errorCode: ErrorCode.unsupportedResource)
                }
            }
            await self?.laneDidFinish(id)
        }
        laneTasks[id] = task
    }

    private func laneDidFinish(_ id: UUID) {
        laneTasks[id] = nil
        laneQuota.release(id)
    }

    private nonisolated static func handleTerminalLane(
        resourceID: String,
        cursor: UInt64?,
        initialInputBytes: Data,
        stream: PeerByteStream
    ) async {
        guard let surfaceID = terminalSurfaceID(resourceID),
              await MainActor.run(body: {
                  GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil
              }) else {
            await reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await sendTerminalOutput(
                    surfaceID: surfaceID,
                    cursor: cursor,
                    stream: stream
                )
                return true
            }
            group.addTask {
                await receiveTerminalInput(
                    surfaceID: surfaceID,
                    initialBytes: initialInputBytes,
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
    }

    /// Returns `true` when the complete lane should close. A clean input-side
    /// finish returns false because the client may intentionally retain an
    /// output-only terminal stream.
    private nonisolated static func receiveTerminalInput(
        surfaceID: UUID,
        initialBytes: Data,
        stream: PeerByteStream
    ) async -> Bool {
        var buffer = Data()
        do {
            var pendingChunk: Data? = initialBytes.isEmpty ? nil : initialBytes
            while !Task.isCancelled {
                let data: Data
                if let chunk = pendingChunk {
                    pendingChunk = nil
                    data = chunk
                } else {
                    guard let received = try await stream.read(
                        maxLength: max(1, maximumInputBufferByteCount - buffer.count)
                    ) else {
                        break
                    }
                    data = received
                }
                guard !data.isEmpty else { continue }
                buffer.append(data)
                guard buffer.count <= maximumInputBufferByteCount else {
                    await reject(stream, errorCode: ErrorCode.invalidInput)
                    return true
                }
                for input in try decodeTerminalInputFrames(from: &buffer) {
                    guard await sendTerminalInput(input, surfaceID: surfaceID) else {
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
        surfaceID: UUID,
        cursor: UInt64?,
        stream: PeerByteStream
    ) async {
        let updates = await MainActor.run {
            guard GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil else {
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
        guard requestedSequence >= replayStart,
              requestedSequence <= currentSequence else {
            await reject(stream, errorCode: ErrorCode.cursorGap)
            return
        }

        var nextSequence = requestedSequence
        do {
            let replayOffset = Int(requestedSequence - replayStart)
            let replayPayload = Data(replayData.dropFirst(replayOffset))
            let replayEnvelope = try MobileHostPeerTerminalOutputEnvelope(
                kind: .replay,
                retainedBaseSequence: replayStart,
                sequence: requestedSequence,
                currentSequence: currentSequence,
                payload: replayPayload
            )
            try await stream.write(
                MobileHostPeerTerminalOutputEnvelopeCodec().encode(replayEnvelope)
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
                try await sendTerminalOutputChunks(
                    Data(chunk.data.dropFirst(offset)),
                    startingAt: nextSequence,
                    stream: stream
                )
                nextSequence = chunkEnd
            }
            try await stream.finish()
        } catch is CancellationError {
            await stream.reset(errorCode: 0)
        } catch {
            await stream.reset(errorCode: ErrorCode.cursorGap)
        }
    }

    private nonisolated static func sendTerminalOutputChunks(
        _ data: Data,
        startingAt startingSequence: UInt64,
        stream: PeerByteStream
    ) async throws {
        let codec = MobileHostPeerTerminalOutputEnvelopeCodec()
        var offset = 0
        while offset < data.count {
            let payloadByteCount = min(
                MobileHostPeerTerminalOutputEnvelope.maximumPayloadByteCount,
                data.count - offset
            )
            let payload = Data(data[offset ..< (offset + payloadByteCount)])
            let sequence = startingSequence + UInt64(offset)
            let currentSequence = sequence + UInt64(payloadByteCount)
            let envelope = try MobileHostPeerTerminalOutputEnvelope(
                kind: .chunk,
                retainedBaseSequence: sequence,
                sequence: sequence,
                currentSequence: currentSequence,
                payload: payload
            )
            try await stream.write(codec.encode(envelope))
            offset += payloadByteCount
        }
    }

    private nonisolated static func sendTerminalInput(
        _ input: String,
        surfaceID: UUID
    ) async -> Bool {
        await MainActor.run {
            guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else {
                return false
            }
            switch surface.sendInputResult(input) {
            case .sent:
                surface.forceRefresh(reason: "mobileHost.peerTerminalLaneInput")
                return true
            case .queued:
                return true
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    private nonisolated static func terminalSurfaceID(
        _ resourceID: String
    ) -> UUID? {
        let rawID = resourceID.hasPrefix("terminal:")
            ? String(resourceID.dropFirst("terminal:".count))
            : resourceID
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
        _ stream: PeerByteStream,
        errorCode: UInt64
    ) async {
        await stream.reset(errorCode: errorCode)
    }
}
