public import Foundation

/// Client-side owner of every server->client event lane on one irx
/// connection: the shared events lane plus one lane per terminal surface.
///
/// Each lane has its own reader task, so a burst on one surface's stream
/// never delays bytes already delivered on another stream. Readers forward
/// only whole mobile-sync frames into the single subscriber stream, which lets
/// the RPC session decode the merged output exactly like one ordered lane:
/// ordering holds per lane, and every surface's frames stay on one lane.
///
/// The hub accepts lanes for the connection lifetime. Keeping one acceptor
/// per connection means a replaced subscriber can never leave a stale accept
/// loop behind that steals the next lane the host opens.
public actor IrxServerEventLaneHub {
    public struct Limits: Sendable {
        public var maximumSurfaceLaneCount: Int
        public var maximumFrameByteCount: Int

        public init(
            maximumSurfaceLaneCount: Int = 32,
            maximumFrameByteCount: Int = 8 * 1024 * 1024
        ) {
            self.maximumSurfaceLaneCount = max(1, maximumSurfaceLaneCount)
            self.maximumFrameByteCount = maximumFrameByteCount
        }
    }

    public typealias AcceptLane = @Sendable () async throws -> (IrxLaneDescriptor, any IrxEventLaneReading)?
    public typealias Output = AsyncThrowingStream<Data, any Error>

    /// Stop codes the hub sends when it refuses a lane.
    public enum StopCode {
        public static let unsupportedLane: UInt64 = 2
        public static let laneLimit: UInt64 = 3
        public static let malformedFrame: UInt64 = 5
    }

    private let acceptLane: AcceptLane
    private let limits: Limits
    private let journal: IrxJournal?
    private var acceptTask: Task<Void, Never>?
    private var readerTasks: [UInt64: Task<Void, Never>] = [:]
    private var readers: [UInt64: any IrxEventLaneReading] = [:]
    private var surfaceLaneIDs: Set<UInt64> = []
    private var nextLaneID: UInt64 = 0
    private var subscriber: Output.Continuation?
    private var subscriberID: UInt64 = 0
    private var didStartSharedLane = false
    private var terminalError: (any Error)?
    private var isFinished = false

    public init(limits: Limits = Limits(), journal: IrxJournal? = nil, acceptLane: @escaping AcceptLane) {
        self.acceptLane = acceptLane
        self.limits = limits
        self.journal = journal
    }

    public var isAlive: Bool { !isFinished }

    public func activeSurfaceLaneCount() -> Int { surfaceLaneIDs.count }

    /// Returns the merged event byte stream, replacing any previous
    /// subscriber (which finishes normally). The first call starts accepting.
    public func subscribe() -> Output {
        let (stream, continuation) = Output.makeStream()
        guard !isFinished else {
            continuation.finish(throwing: terminalError ?? CancellationError())
            return stream
        }
        subscriber?.finish()
        subscriberID &+= 1
        let id = subscriberID
        subscriber = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.subscriberEnded(id: id) }
        }
        if acceptTask == nil {
            acceptTask = Task { [weak self] in await self?.runAcceptLoop() }
        }
        return stream
    }

    /// Stops every lane. The native accept may stay blocked until the
    /// connection closes; any lane it returns afterwards is stopped.
    public func stop() async {
        finish(error: nil)
        let stopping = Array(readers.values)
        readers.removeAll()
        for reader in stopping {
            await reader.stop(errorCode: 0)
        }
    }

    private func subscriberEnded(id: UInt64) {
        guard subscriberID == id else { return }
        subscriber = nil
    }

    private func runAcceptLoop() async {
        while !isFinished {
            let accepted: (IrxLaneDescriptor, any IrxEventLaneReading)?
            do {
                accepted = try await acceptLane()
            } catch {
                finish(error: error)
                return
            }
            guard let (descriptor, reader) = accepted else {
                // Native connection closure ends lane acceptance.
                finish(error: IrxConnectionError.closed(nil))
                return
            }
            await admit(descriptor: descriptor, reader: reader)
        }
    }

    private func admit(descriptor: IrxLaneDescriptor, reader: any IrxEventLaneReading) async {
        guard !isFinished else {
            await reader.stop(errorCode: 0)
            return
        }
        guard descriptor.lane == .events else {
            await reader.stop(errorCode: StopCode.unsupportedLane)
            return
        }
        let surfaceID = IrxSurfaceEventLaneProtocol.surfaceID(of: descriptor)
        if surfaceID != nil, surfaceLaneIDs.count >= limits.maximumSurfaceLaneCount {
            // The host treats a stopped lane as a failed write and falls back.
            journal?.record("client-events", "surface-lane-refused", ["reason": "limit"])
            await reader.stop(errorCode: StopCode.laneLimit)
            return
        }
        nextLaneID &+= 1
        let laneID = nextLaneID
        readers[laneID] = reader
        if surfaceID != nil {
            surfaceLaneIDs.insert(laneID)
        } else {
            didStartSharedLane = true
        }
        journal?.record(
            "client-events", surfaceID == nil ? "lane-accepted" : "surface-lane-accepted",
            ["open_surface_lanes": String(surfaceLaneIDs.count)]
        )
        let maximumFrameByteCount = limits.maximumFrameByteCount
        readerTasks[laneID] = Task { [weak self] in
            var aligner = IrxEventFrameAligner(maximumFrameByteCount: maximumFrameByteCount)
            var stopCode: UInt64?
            do {
                while !Task.isCancelled, let chunk = try await reader.readRaw() {
                    guard !chunk.isEmpty else { continue }
                    guard let frames = try aligner.append(chunk) else { continue }
                    await self?.deliver(frames)
                }
            } catch is IrxEventFrameAligner.Failure {
                stopCode = StopCode.malformedFrame
            } catch {
                // A reset lane only loses its own unfinished frame.
            }
            if let stopCode { await reader.stop(errorCode: stopCode) }
            await self?.laneEnded(laneID: laneID)
        }
    }

    private func deliver(_ frames: Data) {
        subscriber?.yield(frames)
    }

    private func laneEnded(laneID: UInt64) {
        readerTasks.removeValue(forKey: laneID)
        readers.removeValue(forKey: laneID)
        if surfaceLaneIDs.remove(laneID) != nil {
            journal?.record(
                "client-events", "surface-lane-ended",
                ["open_surface_lanes": String(surfaceLaneIDs.count)]
            )
        }
    }

    private func finish(error: (any Error)?) {
        guard !isFinished else { return }
        isFinished = true
        terminalError = error
        acceptTask?.cancel()
        acceptTask = nil
        for task in readerTasks.values { task.cancel() }
        readerTasks.removeAll()
        surfaceLaneIDs.removeAll()
        if let error {
            subscriber?.finish(throwing: error)
        } else {
            subscriber?.finish()
        }
        subscriber = nil
    }
}
