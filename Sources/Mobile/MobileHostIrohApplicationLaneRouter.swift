import CmuxAgentChat
import CmuxIrohTransport
import Darwin
import Dispatch
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

/// Safe fallback for hosts that do not install an artifact resource owner.
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

enum MobileHostIrohArtifactTransferIssueFailure: Equatable, Sendable {
    case fileNotFound
    case unavailable
}

/// Runtime-scoped, peer-bound capabilities minted only after control-RPC authorization.
actor MobileHostIrohArtifactTransferRegistry {
    enum Error: Swift.Error, Equatable {
        case unavailable
        case invalidFile
        case capacityExceeded
        case unknownResource
        case expired
        case peerMismatch
        case invalidOffset
        case alreadyInUse
        case resumeLimitExceeded

        var issueFailure: MobileHostIrohArtifactTransferIssueFailure {
            switch self {
            case .invalidFile:
                .fileNotFound
            case .unavailable, .capacityExceeded, .unknownResource, .expired,
                 .peerMismatch, .invalidOffset, .alreadyInUse, .resumeLimitExceeded:
                .unavailable
            }
        }
    }

    struct Lease: Equatable, Sendable {
        let id: UUID
        let resourceID: CmxIrohResourceID
        let canonicalPath: String
        let identity: MobileHostIrohArtifactFileIdentity
        let offset: UInt64
        let totalSize: Int64
    }

    private struct Entry: Sendable {
        let peer: CmxIrohAdmittedPeer
        let canonicalPath: String
        let identity: MobileHostIrohArtifactFileIdentity
        let expiresAt: Date
        var activeLeaseID: UUID?
        var remainingClaims: Int
    }

    private static let maximumEntryCount = 128
    private static let maximumSerialClaimCount = 8
    private static let defaultTimeToLive: TimeInterval = 5 * 60

    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private let resourceID: @Sendable () throws -> CmxIrohResourceID
    private var entries: [CmxIrohResourceID: Entry] = [:]

    init(
        timeToLive: TimeInterval = defaultTimeToLive,
        // A closure literal, not `Date.init`: the initializer reference
        // resolves as a non-@Sendable function value and trips the Swift 6
        // data-race warning (zero-bucket file in the warning budget).
        now: @escaping @Sendable () -> Date = { Date() },
        resourceID: @escaping @Sendable () throws -> CmxIrohResourceID = {
            let token = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            return try CmxIrohResourceID("artifact:\(token)")
        }
    ) {
        self.timeToLive = max(1, timeToLive)
        self.now = now
        self.resourceID = resourceID
    }

    func issue(
        canonicalPath: String,
        peer: CmxIrohAdmittedPeer
    ) throws -> ChatArtifactLaneDescriptor {
        let currentTime = now()
        pruneExpired(at: currentTime)
        guard entries.count < Self.maximumEntryCount else {
            throw Error.capacityExceeded
        }
        let resolvedPath = URL(fileURLWithPath: canonicalPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let identity = try MobileHostIrohArtifactFileIdentity.snapshot(path: resolvedPath)
        guard identity.size >= 0 else { throw Error.invalidFile }
        let capability = try resourceID()
        guard entries[capability] == nil else { throw Error.capacityExceeded }
        let expiresAt = currentTime.addingTimeInterval(timeToLive)
        entries[capability] = Entry(
            peer: peer,
            canonicalPath: resolvedPath,
            identity: identity,
            expiresAt: expiresAt,
            activeLeaseID: nil,
            remainingClaims: Self.maximumSerialClaimCount
        )
        return ChatArtifactLaneDescriptor(
            resourceID: capability.value,
            totalSize: identity.size,
            expiresAt: expiresAt
        )
    }

    func claim(
        resourceID: CmxIrohResourceID,
        offset: UInt64,
        peer: CmxIrohAdmittedPeer
    ) throws -> Lease {
        let currentTime = now()
        guard var entry = entries[resourceID] else { throw Error.unknownResource }
        guard entry.expiresAt > currentTime else {
            entries[resourceID] = nil
            throw Error.expired
        }
        guard entry.peer == peer else { throw Error.peerMismatch }
        guard offset <= UInt64(entry.identity.size) else { throw Error.invalidOffset }
        guard entry.activeLeaseID == nil else { throw Error.alreadyInUse }
        guard entry.remainingClaims > 0 else { throw Error.resumeLimitExceeded }
        let leaseID = UUID()
        entry.activeLeaseID = leaseID
        entry.remainingClaims -= 1
        entries[resourceID] = entry
        return Lease(
            id: leaseID,
            resourceID: resourceID,
            canonicalPath: entry.canonicalPath,
            identity: entry.identity,
            offset: offset,
            totalSize: entry.identity.size
        )
    }

    func release(_ lease: Lease) {
        guard var entry = entries[lease.resourceID],
              entry.activeLeaseID == lease.id else { return }
        entry.activeLeaseID = nil
        entries[lease.resourceID] = entry
    }

    private func pruneExpired(at currentTime: Date) {
        entries = entries.filter { _, entry in
            entry.activeLeaseID != nil || entry.expiresAt > currentTime
        }
    }
}

struct MobileHostIrohArtifactFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    static func snapshot(path: String) throws -> Self {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try snapshot(fileDescriptor: handle.fileDescriptor)
    }

    static func snapshot(fileDescriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(fileDescriptor, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG else {
            throw MobileHostIrohArtifactTransferRegistry.Error.invalidFile
        }
        return Self(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

/// Random-access file reader backed by DispatchIO so a slow file system never
/// blocks Swift's cooperative executor. Cancelling a lane stops pending I/O.
private final class MobileHostIrohArtifactDispatchReader: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "dev.cmux.mobile-host-iroh-artifact-read",
        qos: .utility
    )

    private let fileDescriptor: Int32
    private let channel: DispatchIO

    init(path: String) throws {
        let fileDescriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            throw MobileHostIrohArtifactTransferRegistry.Error.invalidFile
        }
        self.fileDescriptor = fileDescriptor
        self.channel = DispatchIO(
            type: .random,
            fileDescriptor: fileDescriptor,
            queue: Self.queue
        ) { _ in
            _ = Darwin.close(fileDescriptor)
        }
        channel.setLimit(lowWater: 1)
    }

    func snapshot() throws -> MobileHostIrohArtifactFileIdentity {
        try MobileHostIrohArtifactFileIdentity.snapshot(fileDescriptor: fileDescriptor)
    }

    func read(offset: UInt64, maximumByteCount: Int) async throws -> Data {
        guard offset <= UInt64(Int64.max), maximumByteCount > 0 else {
            throw MobileHostIrohArtifactTransferRegistry.Error.invalidOffset
        }
        try Task.checkCancellation()
        let channel = channel
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                let result = MobileHostIrohArtifactDispatchReadResult(
                    continuation: continuation
                )
                channel.read(
                    offset: off_t(offset),
                    length: maximumByteCount,
                    queue: Self.queue
                ) { done, bytes, errorCode in
                    result.receive(done: done, bytes: bytes, errorCode: errorCode)
                }
            }
        } onCancel: {
            channel.close(flags: .stop)
        }
        try Task.checkCancellation()
        return data
    }

    func close() {
        channel.close()
    }
}

/// DispatchIO may deliver one read through several callbacks on its serial queue.
private final class MobileHostIrohArtifactDispatchReadResult: @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, any Error>
    private var data = Data()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func receive(done: Bool, bytes: DispatchData?, errorCode: Int32) {
        guard !didResume else { return }
        if let bytes {
            data.append(contentsOf: bytes)
        }
        guard done else { return }
        didResume = true
        if errorCode == 0 {
            continuation.resume(returning: data)
        } else {
            continuation.resume(
                throwing: POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            )
        }
    }
}

/// Concrete Mac owner for low-priority raw artifact bytes.
struct MobileHostIrohArtifactLaneHandler: MobileHostIrohArtifactLaneHandling {
    private static let chunkByteCount = 64 * 1_024
    // noq transmits larger priorities first. Keep artifact bytes below terminal
    // streams (default 0) and server events (50).
    private static let streamPriority: Int32 = -10
    private static let streamFailureCode: UInt64 = 6

    let registry: MobileHostIrohArtifactTransferRegistry

    func handleArtifactLane(
        resourceID: CmxIrohResourceID,
        offset: UInt64,
        stream: CmxIrohBidirectionalStream,
        peer: CmxIrohAdmittedPeer
    ) async -> Bool {
        let lease: MobileHostIrohArtifactTransferRegistry.Lease
        do {
            lease = try await registry.claim(
                resourceID: resourceID,
                offset: offset,
                peer: peer
            )
        } catch {
            return false
        }

        do {
            let reader = try MobileHostIrohArtifactDispatchReader(path: lease.canonicalPath)
            defer { reader.close() }
            guard try reader.snapshot() == lease.identity else {
                throw MobileHostIrohArtifactTransferRegistry.Error.invalidFile
            }
            try await stream.sendStream.setPriority(Self.streamPriority)
            await stream.receiveStream.stop(errorCode: 0)
            let totalSize = UInt64(lease.totalSize)
            var readOffset = lease.offset
            while readOffset < totalSize {
                try Task.checkCancellation()
                let remainingByteCount = totalSize - readOffset
                let readByteCount = Int(min(
                    UInt64(Self.chunkByteCount),
                    remainingByteCount
                ))
                let data = try await reader.read(
                    offset: readOffset,
                    maximumByteCount: readByteCount
                )
                guard !data.isEmpty else {
                    throw MobileHostIrohArtifactTransferRegistry.Error.invalidFile
                }
                try Task.checkCancellation()
                try await stream.sendStream.send(data)
                readOffset += UInt64(data.count)
            }
            try Task.checkCancellation()
            guard try reader.snapshot() == lease.identity else {
                throw MobileHostIrohArtifactTransferRegistry.Error.invalidFile
            }
            try await stream.sendStream.finish()
        } catch is CancellationError {
            await stream.sendStream.reset(errorCode: 0)
            await stream.receiveStream.stop(errorCode: 0)
        } catch {
            await stream.sendStream.reset(errorCode: Self.streamFailureCode)
            await stream.receiveStream.stop(errorCode: Self.streamFailureCode)
        }
        await registry.release(lease)
        return true
    }
}

/// Separate credits prevent terminal fan-out from starving one artifact lane.
struct MobileHostIrohApplicationLaneQuota {
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

/// Sole Mac-side accept owner for post-admission Iroh application streams.
///
/// Terminal lanes route a validated surface UUID to sequence-framed PTY output
/// and bounded, length-prefixed UTF-8 input. Artifact lanes are delegated through one
/// registration seam and otherwise reset. Every task is owned by this admitted
/// session and cancelled when the control connection or runtime generation ends.
actor MobileHostIrohApplicationLaneRouter {
    static let maximumConcurrentTerminalLaneCount =
        UInt64(MobileHostIrohApplicationLaneQuota.maximumTerminalCount)
    static let maximumConcurrentArtifactLaneCount =
        UInt64(MobileHostIrohApplicationLaneQuota.maximumArtifactCount)
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

    private let session: CmxIrohAdmittedServerSession
    private let artifactHandler: any MobileHostIrohArtifactLaneHandling
    private var laneTasks: [UUID: Task<Void, Never>] = [:]
    private var laneQuota = MobileHostIrohApplicationLaneQuota()
    private var stopped = false

    init(
        session: CmxIrohAdmittedServerSession,
        artifactHandler: any MobileHostIrohArtifactLaneHandling = MobileHostIrohRejectingArtifactLaneHandler()
    ) {
        self.session = session
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
        laneQuota = MobileHostIrohApplicationLaneQuota()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func start(
        _ lane: CmxIrohLane,
        stream: CmxIrohBidirectionalStream
    ) async {
        let laneClass: MobileHostIrohApplicationLaneQuota.LaneClass
        switch lane {
        case .terminal:
            laneClass = .terminal
        case .artifact:
            laneClass = .artifact
        case .control, .serverEvents:
            await Self.reject(stream, errorCode: ErrorCode.unsupportedResource)
            return
        }
        let id = UUID()
        guard laneQuota.reserve(id, laneClass: laneClass) else {
            await Self.reject(stream, errorCode: ErrorCode.quotaExceeded)
            return
        }
        let peer = session.peer
        let artifactHandler = artifactHandler
        let task = Task { [weak self] in
            switch lane {
            case let .terminal(resourceID, cursor):
                await Self.handleTerminalLane(
                    resourceID: resourceID,
                    cursor: cursor,
                    stream: stream
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
        laneQuota.release(id)
    }

    private nonisolated static func handleTerminalLane(
        resourceID: CmxIrohResourceID,
        cursor: UInt64?,
        stream: CmxIrohBidirectionalStream
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
        await stream.receiveStream.stop(errorCode: 0)
    }

    /// Returns `true` when the complete lane should close. A clean input-side
    /// finish returns false because the client may intentionally retain an
    /// output-only terminal stream.
    private nonisolated static func receiveTerminalInput(
        surfaceID: UUID,
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
        stream: CmxIrohBidirectionalStream
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
                try await sendTerminalOutputChunks(
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
                surface.forceRefresh(reason: "mobileHost.irohTerminalLaneInput")
                return true
            case .queued:
                return true
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
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
