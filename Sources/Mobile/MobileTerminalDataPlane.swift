import CmuxTerminalBackend
import CmuxTerminalBackendService
import Foundation

enum MobileTerminalDataPlaneProfile: Equatable, Sendable {
    case embeddedGhostty
    case backendCompatibility

    nonisolated var terminalFidelity: String {
        switch self {
        case .embeddedGhostty: "render_grid"
        case .backendCompatibility: "noncanonical_byte_stream"
        }
    }

    nonisolated var compatibilityCapability: String? {
        switch self {
        case .embeddedGhostty: nil
        case .backendCompatibility: "terminal.byte_stream.compat.v1"
        }
    }
}

struct MobileTerminalDataPlaneReplay: Equatable, Sendable {
    let sequence: UInt64
    let columns: Int
    let rows: Int
    let data: Data
    let snapshotFormat: String
    let fidelity: String
}

struct MobileTerminalDataPlaneFrame: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case replay
        case chunk
    }

    let kind: Kind
    let retainedBaseSequence: UInt64
    let sequence: UInt64
    let currentSequence: UInt64
    let data: Data
}

enum MobileTerminalDataPlaneError: Error, Equatable, Sendable {
    case unavailable
    case surfaceNotFound
    case cursorGap
    case generationChanged
    case streamOverflow
    case streamAlreadyClaimed
}

protocol MobileTerminalDataPlaneLane: Sendable {
    func frames() async throws -> AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>
    func sendInput(_ text: String) async throws
    func close() async
}

protocol MobileTerminalDataPlane: Sendable {
    nonisolated var profile: MobileTerminalDataPlaneProfile { get }
    func replay(surfaceID: UUID) async throws -> MobileTerminalDataPlaneReplay
    func openLane(
        surfaceID: UUID,
        cursor: UInt64?
    ) async throws -> any MobileTerminalDataPlaneLane
}

/// Persistent-mode fail-closed default for tests and incomplete composition.
/// It deliberately cannot fall back to the process-local Ghostty byte tee.
struct UnavailablePersistentMobileTerminalDataPlane: MobileTerminalDataPlane {
    nonisolated let profile = MobileTerminalDataPlaneProfile.backendCompatibility

    func replay(surfaceID _: UUID) async throws -> MobileTerminalDataPlaneReplay {
        throw MobileTerminalDataPlaneError.unavailable
    }

    func openLane(
        surfaceID _: UUID,
        cursor _: UInt64?
    ) async throws -> any MobileTerminalDataPlaneLane {
        throw MobileTerminalDataPlaneError.unavailable
    }
}

private struct UnavailableMobileTerminalInputAuthority:
    BackendTerminalCompatibilityInputAuthority {
    func authorizeTerminalCompatibilityInput(
        surfaceID _: SurfaceID,
        delegateIdentity _: BackendClientRegistrationIdentity,
        replacing _: BackendTerminalInputDelegation?
    ) async throws -> BackendTerminalInputDelegation {
        throw MobileTerminalDataPlaneError.unavailable
    }

    func revokeTerminalCompatibilityInput(
        surfaceID _: SurfaceID,
        delegateIdentity _: BackendClientRegistrationIdentity,
        delegation _: BackendTerminalInputDelegation
    ) async throws {}
}

/// Embedded-mode adapter over the existing libghostty PTY tee.
actor EmbeddedMobileTerminalDataPlane: MobileTerminalDataPlane {
    nonisolated let profile = MobileTerminalDataPlaneProfile.embeddedGhostty

    func replay(surfaceID: UUID) async throws -> MobileTerminalDataPlaneReplay {
        try await MainActor.run {
            guard GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil else {
                throw MobileTerminalDataPlaneError.surfaceNotFound
            }
            let state = MobileTerminalByteTee.shared.replayState(surfaceID: surfaceID)
            return MobileTerminalDataPlaneReplay(
                sequence: state?.seq ?? 0,
                columns: 0,
                rows: 0,
                data: state?.data ?? Data(),
                snapshotFormat: "ghostty.raw-byte-tail",
                fidelity: "ghostty_bytes"
            )
        }
    }

    func openLane(
        surfaceID: UUID,
        cursor: UInt64?
    ) async throws -> any MobileTerminalDataPlaneLane {
        let source = try await MainActor.run {
            guard GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) != nil else {
                throw MobileTerminalDataPlaneError.surfaceNotFound
            }
            // Install the subscriber before reading replay state. Output that
            // races the snapshot is retained in both places and removed by the
            // sequence-overlap logic in the lane.
            return (
                MobileTerminalByteTee.shared.outputUpdates(surfaceID: surfaceID),
                MobileTerminalByteTee.shared.replayState(surfaceID: surfaceID)
            )
        }
        return try EmbeddedMobileTerminalDataPlaneLane(
            surfaceID: surfaceID,
            cursor: cursor,
            updates: source.0,
            replay: source.1,
            input: { text in
                try await MainActor.run {
                    guard let surface = GhosttyApp.terminalSurfaceRegistry
                        .terminalSurface(id: surfaceID) else {
                        throw MobileTerminalDataPlaneError.surfaceNotFound
                    }
                    guard surface.sendInputResult(text).accepted else {
                        throw MobileTerminalDataPlaneError.unavailable
                    }
                    surface.forceRefresh(reason: "mobileHost.irohTerminalLaneInput")
                }
            }
        )
    }
}

private actor EmbeddedMobileTerminalDataPlaneLane: MobileTerminalDataPlaneLane {
    private let stream: AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>
    private let input: @Sendable (String) async throws -> Void
    private var producer: Task<Void, Never>?
    private var framesClaimed = false

    init(
        surfaceID _: UUID,
        cursor: UInt64?,
        updates: AsyncStream<MobileTerminalByteTee.OutputChunk>,
        replay: (seq: UInt64, data: Data)?,
        input: @escaping @Sendable (String) async throws -> Void
    ) throws {
        let currentSequence = replay?.seq ?? 0
        let replayData = replay?.data ?? Data()
        guard UInt64(replayData.count) <= currentSequence else {
            throw MobileTerminalDataPlaneError.cursorGap
        }
        let replayStart = currentSequence - UInt64(replayData.count)
        let requestedSequence = cursor ?? replayStart
        guard requestedSequence >= replayStart,
              requestedSequence <= currentSequence else {
            throw MobileTerminalDataPlaneError.cursorGap
        }
        let pair = AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        stream = pair.stream
        self.input = input
        producer = Task {
            var nextSequence = requestedSequence
            let replayOffset = Int(requestedSequence - replayStart)
            let replayPayload = Data(replayData.dropFirst(replayOffset))
            guard Self.yield(
                MobileTerminalDataPlaneFrame(
                    kind: .replay,
                    retainedBaseSequence: replayStart,
                    sequence: requestedSequence,
                    currentSequence: currentSequence,
                    data: replayPayload
                ),
                to: pair.continuation
            ) else { return }
            nextSequence = currentSequence
            for await chunk in updates {
                guard !Task.isCancelled else { break }
                let chunkEnd = chunk.sequence + UInt64(chunk.data.count)
                if chunkEnd <= nextSequence { continue }
                guard chunk.sequence <= nextSequence else {
                    pair.continuation.finish(throwing: MobileTerminalDataPlaneError.cursorGap)
                    return
                }
                let offset = Int(nextSequence - chunk.sequence)
                let payload = Data(chunk.data.dropFirst(offset))
                guard Self.yield(
                    MobileTerminalDataPlaneFrame(
                        kind: .chunk,
                        retainedBaseSequence: nextSequence,
                        sequence: nextSequence,
                        currentSequence: chunkEnd,
                        data: payload
                    ),
                    to: pair.continuation
                ) else { return }
                nextSequence = chunkEnd
            }
            pair.continuation.finish()
        }
    }

    deinit { producer?.cancel() }

    func frames() async throws -> AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error> {
        guard !framesClaimed else {
            throw MobileTerminalDataPlaneError.streamAlreadyClaimed
        }
        framesClaimed = true
        return stream
    }

    func sendInput(_ text: String) async throws {
        try await input(text)
    }

    func close() {
        producer?.cancel()
        producer = nil
    }

    private nonisolated static func yield(
        _ frame: MobileTerminalDataPlaneFrame,
        to continuation: AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>.Continuation
    ) -> Bool {
        switch continuation.yield(frame) {
        case .enqueued:
            return true
        case .dropped:
            continuation.finish(throwing: MobileTerminalDataPlaneError.streamOverflow)
            return false
        case .terminated:
            return false
        @unknown default:
            continuation.finish(throwing: MobileTerminalDataPlaneError.unavailable)
            return false
        }
    }
}

protocol MobileBackendTerminalCompatibilitySession: Sendable {
    func events() async throws -> AsyncThrowingStream<BackendTerminalCompatibilityEvent, any Error>
    func sendInput(_ text: String) async throws
    func close() async
}

extension BackendTerminalCompatibilitySession: MobileBackendTerminalCompatibilitySession {}

struct MobileBackendTerminalCompatibilityAttachment: Sendable {
    let clientUUID: UUID
    let session: any MobileBackendTerminalCompatibilitySession
    let snapshot: BackendTerminalCompatibilitySnapshot
}

/// Backend-mode owner of replay-to-Iroh handoff sessions.
///
/// `replay` leaves its exact cmuxd attach connection pending. `openLane`
/// consumes that same connection only when the phone presents the replay's
/// cursor, so output produced between the RPC and QUIC lane cannot disappear.
/// Several phones can race on one surface because today's lane header carries
/// only a cursor, not a client token. Equal-cursor handoffs therefore consume
/// the oldest pending attachment first. The FIFO is globally bounded and each
/// entry expires, so an abandoned RPC cannot retain a daemon connection.
actor PersistentMobileTerminalDataPlane: MobileTerminalDataPlane {
    typealias ReadinessProvider = @Sendable () async throws -> BackendServiceBootstrapResult
    typealias SessionFactory = @Sendable (_ surfaceID: UUID, _ clientUUID: UUID) async throws ->
        MobileBackendTerminalCompatibilityAttachment
    typealias ClientUUIDProvider = @Sendable () -> UUID
    typealias PendingSleep = @Sendable (Duration) async throws -> Void

    static let defaultMaximumPendingReplayCount = 16
    static let defaultMaximumPendingReplayBytes = 16 * 1_024 * 1_024
    static let defaultPendingReplayTTL = Duration.seconds(15)
    static let maximumClientUUIDAllocationAttempts = 8
    /// Cursorless compatibility lanes use a fixed wire-space offset so a
    /// synthesized VT snapshot can be represented without pretending its byte
    /// length is part of cmuxd's canonical raw-output history. The offset is
    /// stable across reconnects and large enough for every accepted snapshot.
    static let virtualReplayCursorOffset = UInt64(
        BackendTerminalCompatibilitySession.maximumReplayBytes
    )
    /// Slow phones get two one-megabyte output slots in the compatibility
    /// stage and two more in the mobile lane. Both stages fail closed on the
    /// next frame, bounding retention to a few MiB plus transient base64 decode.
    static let maximumBufferedEventsPerCompatibilityStage = 2
    static let maximumBufferedFramesPerLane = 2

    private struct ReservedAttachment: Sendable {
        let attachment: MobileBackendTerminalCompatibilityAttachment
        let reservationToken: UUID
    }

    private struct PendingReplay {
        let id: UUID
        let surfaceID: UUID
        let reservedAttachment: ReservedAttachment
    }

    nonisolated let profile = MobileTerminalDataPlaneProfile.backendCompatibility
    private let sessionFactory: SessionFactory
    private let maximumPendingReplayCount: Int
    private let maximumPendingReplayBytes: Int
    private let pendingReplayTTL: Duration
    private let pendingSleep: PendingSleep
    private let clientUUIDProvider: ClientUUIDProvider
    private var pendingByID: [UUID: PendingReplay] = [:]
    private var pendingIDsBySurfaceID: [UUID: [UUID]] = [:]
    private var pendingOrder: [UUID] = []
    private var pendingReplayBytes = 0
    private var expirationTasksByID: [UUID: Task<Void, Never>] = [:]
    private var clientUUIDReservationTokens: [UUID: UUID] = [:]

    init(
        readinessProvider: @escaping ReadinessProvider,
        socketPath: String,
        processInstanceUUID: UUID,
        inputAuthority: any BackendTerminalCompatibilityInputAuthority =
            UnavailableMobileTerminalInputAuthority(),
        clientUUIDProvider: @escaping ClientUUIDProvider = { UUID() },
        maximumPendingReplayCount: Int = defaultMaximumPendingReplayCount,
        maximumPendingReplayBytes: Int = defaultMaximumPendingReplayBytes,
        pendingReplayTTL: Duration = defaultPendingReplayTTL,
        pendingSleep: @escaping PendingSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.init(
            sessionFactory: { surfaceID, clientUUID in
                let readiness: BackendServiceReadiness
                switch try await readinessProvider() {
                case .ready(let value):
                    readiness = value
                case .disabled, .requiresApproval, .missingBundleItem,
                     .serviceNotFound, .backendUnavailable:
                    throw MobileTerminalDataPlaneError.unavailable
                }
                guard let registrationIdentity = BackendClientRegistrationIdentity(
                    clientUUID: clientUUID,
                    processInstanceUUID: processInstanceUUID
                ) else {
                    throw MobileTerminalDataPlaneError.unavailable
                }
                let session = BackendTerminalCompatibilitySession(
                    transport: UnixBackendTransport(path: socketPath),
                    expectation: BackendCanonicalSessionExpectation(
                        session: readiness.session,
                        authority: readiness.authority,
                        processID: readiness.processID,
                        peerIdentity: readiness.peerIdentity
                    ),
                    registrationIdentity: registrationIdentity,
                    inputAuthority: inputAuthority,
                    eventCapacity:
                        PersistentMobileTerminalDataPlane
                            .maximumBufferedEventsPerCompatibilityStage
                )
                do {
                    let snapshot = try await session.attach(
                        surfaceID: SurfaceID(rawValue: surfaceID)
                    )
                    return MobileBackendTerminalCompatibilityAttachment(
                        clientUUID: clientUUID,
                        session: session,
                        snapshot: snapshot
                    )
                } catch {
                    await session.close()
                    throw error
                }
            },
            maximumPendingReplayCount: maximumPendingReplayCount,
            maximumPendingReplayBytes: maximumPendingReplayBytes,
            pendingReplayTTL: pendingReplayTTL,
            pendingSleep: pendingSleep,
            clientUUIDProvider: clientUUIDProvider
        )
    }

    init(
        sessionFactory: @escaping SessionFactory,
        maximumPendingReplayCount: Int,
        maximumPendingReplayBytes: Int = defaultMaximumPendingReplayBytes,
        pendingReplayTTL: Duration,
        pendingSleep: @escaping PendingSleep,
        clientUUIDProvider: @escaping ClientUUIDProvider = { UUID() }
    ) {
        precondition(maximumPendingReplayCount > 0)
        precondition(maximumPendingReplayBytes > 0)
        self.sessionFactory = sessionFactory
        self.maximumPendingReplayCount = maximumPendingReplayCount
        self.maximumPendingReplayBytes = maximumPendingReplayBytes
        self.pendingReplayTTL = pendingReplayTTL
        self.pendingSleep = pendingSleep
        self.clientUUIDProvider = clientUUIDProvider
    }

    func replay(surfaceID: UUID) async throws -> MobileTerminalDataPlaneReplay {
        let reserved = try await makeAttachment(surfaceID: surfaceID)
        try await storePending(surfaceID: surfaceID, reservedAttachment: reserved)
        return Self.replayValue(reserved.attachment.snapshot)
    }

    func openLane(
        surfaceID: UUID,
        cursor: UInt64?
    ) async throws -> any MobileTerminalDataPlaneLane {
        let reserved: ReservedAttachment
        let cursorSpace: PersistentMobileTerminalDataPlaneLane.CursorSpace
        if let cursor,
           let pending = takeOldestPending(surfaceID: surfaceID, cursor: cursor) {
            reserved = pending.reservedAttachment
            cursorSpace = .canonicalHandoff
        } else {
            reserved = try await makeAttachment(surfaceID: surfaceID)
            cursorSpace = .virtualReplay
        }
        do {
            return try await PersistentMobileTerminalDataPlaneLane(
                session: reserved.attachment.session,
                snapshot: reserved.attachment.snapshot,
                requestedCursor: cursor,
                cursorSpace: cursorSpace,
                onClose: { [weak self] in
                    await self?.releaseClientUUID(
                        reserved.attachment.clientUUID,
                        reservationToken: reserved.reservationToken
                    )
                }
            )
        } catch {
            await reserved.attachment.session.close()
            releaseClientUUID(
                reserved.attachment.clientUUID,
                reservationToken: reserved.reservationToken
            )
            throw error
        }
    }

    func closePendingReplays() async {
        let ids = pendingOrder
        let pending = ids.compactMap { removePending(id: $0) }
        for replay in pending { await retire(replay.reservedAttachment) }
    }

    func pendingReplayCountForTesting() -> Int {
        pendingByID.count
    }

    func pendingReplayBytesForTesting() -> Int {
        pendingReplayBytes
    }

    func liveClientUUIDsForTesting() -> Set<UUID> {
        Set(clientUUIDReservationTokens.keys)
    }

    private func makeAttachment(
        surfaceID: UUID
    ) async throws -> ReservedAttachment {
        for _ in 0 ..< Self.maximumClientUUIDAllocationAttempts {
            let clientUUID = clientUUIDProvider()
            guard !clientUUID.isNil,
                  clientUUIDReservationTokens[clientUUID] == nil else {
                continue
            }
            let reservationToken = UUID()
            clientUUIDReservationTokens[clientUUID] = reservationToken
            do {
                let attachment = try await sessionFactory(surfaceID, clientUUID)
                guard attachment.clientUUID == clientUUID else {
                    await attachment.session.close()
                    releaseClientUUID(
                        clientUUID,
                        reservationToken: reservationToken
                    )
                    throw MobileTerminalDataPlaneError.unavailable
                }
                return ReservedAttachment(
                    attachment: attachment,
                    reservationToken: reservationToken
                )
            } catch {
                releaseClientUUID(
                    clientUUID,
                    reservationToken: reservationToken
                )
                throw error
            }
        }
        throw MobileTerminalDataPlaneError.unavailable
    }

    private func storePending(
        surfaceID: UUID,
        reservedAttachment: ReservedAttachment
    ) async throws {
        let replayBytes = reservedAttachment.attachment.snapshot.replay.count
        guard replayBytes <= maximumPendingReplayBytes else {
            await retire(reservedAttachment)
            throw MobileTerminalDataPlaneError.streamOverflow
        }
        var evictedAttachments: [ReservedAttachment] = []
        while pendingOrder.count >= maximumPendingReplayCount
                || pendingReplayBytes > maximumPendingReplayBytes - replayBytes,
               let oldestID = pendingOrder.first,
               let evicted = removePending(id: oldestID) {
            evictedAttachments.append(evicted.reservedAttachment)
        }
        let id = UUID()
        let pending = PendingReplay(
            id: id,
            surfaceID: surfaceID,
            reservedAttachment: reservedAttachment
        )
        pendingByID[id] = pending
        pendingIDsBySurfaceID[surfaceID, default: []].append(id)
        pendingOrder.append(id)
        pendingReplayBytes += replayBytes
        let sleep = pendingSleep
        let ttl = pendingReplayTTL
        expirationTasksByID[id] = Task { [weak self] in
            do {
                try await sleep(ttl)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.expirePending(id: id)
        }
        for attachment in evictedAttachments { await retire(attachment) }
    }

    private func takeOldestPending(
        surfaceID: UUID,
        cursor: UInt64
    ) -> PendingReplay? {
        guard let id = pendingIDsBySurfaceID[surfaceID]?.first(where: {
            pendingByID[$0]?.reservedAttachment.attachment.snapshot.sequence == cursor
        }) else { return nil }
        return removePending(id: id)
    }

    private func expirePending(id: UUID) async {
        guard let expired = removePending(id: id, cancelExpiration: false) else {
            return
        }
        await retire(expired.reservedAttachment)
    }

    private func removePending(
        id: UUID,
        cancelExpiration: Bool = true
    ) -> PendingReplay? {
        guard let pending = pendingByID.removeValue(forKey: id) else { return nil }
        pendingReplayBytes -= pending.reservedAttachment.attachment.snapshot.replay.count
        if let expiration = expirationTasksByID.removeValue(forKey: id),
           cancelExpiration {
            expiration.cancel()
        }
        pendingOrder.removeAll { $0 == id }
        pendingIDsBySurfaceID[pending.surfaceID]?.removeAll { $0 == id }
        if pendingIDsBySurfaceID[pending.surfaceID]?.isEmpty == true {
            pendingIDsBySurfaceID[pending.surfaceID] = nil
        }
        return pending
    }

    private func retire(_ reserved: ReservedAttachment) async {
        await reserved.attachment.session.close()
        releaseClientUUID(
            reserved.attachment.clientUUID,
            reservationToken: reserved.reservationToken
        )
    }

    private func releaseClientUUID(
        _ clientUUID: UUID,
        reservationToken: UUID
    ) {
        guard clientUUIDReservationTokens[clientUUID] == reservationToken else {
            return
        }
        clientUUIDReservationTokens.removeValue(forKey: clientUUID)
    }

    private nonisolated static func replayValue(
        _ snapshot: BackendTerminalCompatibilitySnapshot
    ) -> MobileTerminalDataPlaneReplay {
        MobileTerminalDataPlaneReplay(
            sequence: snapshot.sequence,
            columns: Int(snapshot.columns),
            rows: Int(snapshot.rows),
            data: snapshot.replay,
            snapshotFormat: "cmuxd.compatibility.vt",
            fidelity: BackendTerminalCompatibilitySnapshot.fidelity
        )
    }
}

private actor PersistentMobileTerminalDataPlaneLane: MobileTerminalDataPlaneLane {
    enum CursorSpace: Sendable {
        /// The RPC replay call already delivered the synthesized snapshot. Its
        /// pending attach connection continues at cmuxd's canonical cursor.
        case canonicalHandoff
        /// A direct lane represents the snapshot in a separate, fixed-offset
        /// wire coordinate space and maps later raw output into that space.
        case virtualReplay
    }

    private let session: any MobileBackendTerminalCompatibilitySession
    private let stream: AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>
    private let onClose: @Sendable () async -> Void
    private var producer: Task<Void, Never>?
    private var framesClaimed = false

    init(
        session: any MobileBackendTerminalCompatibilitySession,
        snapshot: BackendTerminalCompatibilitySnapshot,
        requestedCursor: UInt64?,
        cursorSpace: CursorSpace,
        onClose: @escaping @Sendable () async -> Void
    ) async throws {
        guard snapshot.replay.count <= BackendTerminalCompatibilitySession.maximumReplayBytes else {
            await session.close()
            throw MobileTerminalDataPlaneError.streamOverflow
        }
        let transportBase: UInt64
        switch cursorSpace {
        case .canonicalHandoff:
            guard requestedCursor == snapshot.sequence else {
                await session.close()
                throw MobileTerminalDataPlaneError.cursorGap
            }
            transportBase = snapshot.sequence
        case .virtualReplay:
            do {
                transportBase = try snapshot.sequence.addingWithoutOverflow(
                    PersistentMobileTerminalDataPlane.virtualReplayCursorOffset
                )
            } catch {
                await session.close()
                throw error
            }
            if let requestedCursor, requestedCursor != transportBase {
                await session.close()
                throw MobileTerminalDataPlaneError.cursorGap
            }
        }
        self.session = session
        self.onClose = onClose
        let source = try await session.events()
        let pair = AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(
                PersistentMobileTerminalDataPlane.maximumBufferedFramesPerLane
            )
        )
        stream = pair.stream
        producer = Task {
            do {
                let sourceBase = snapshot.sequence
                var emittedInitial = false
                for try await event in source {
                    try Task.checkCancellation()
                    switch event {
                    case .snapshot(let initial):
                        guard !emittedInitial, initial == snapshot else {
                            throw MobileTerminalDataPlaneError.cursorGap
                        }
                        emittedInitial = true
                        let replayData: Data
                        let replayStart: UInt64
                        if requestedCursor != nil {
                            replayData = Data()
                            replayStart = transportBase
                        } else {
                            replayData = initial.replay
                            replayStart = transportBase - UInt64(replayData.count)
                        }
                        try Self.yield(
                            MobileTerminalDataPlaneFrame(
                                kind: .replay,
                                retainedBaseSequence: replayStart,
                                sequence: replayStart,
                                currentSequence: transportBase,
                                data: replayData
                            ),
                            to: pair.continuation
                        )

                    case .output(let output):
                        guard emittedInitial,
                              output.startSequence >= sourceBase else {
                            throw MobileTerminalDataPlaneError.cursorGap
                        }
                        let delta = output.startSequence - sourceBase
                        let mappedStart = try transportBase.addingWithoutOverflow(delta)
                        let mappedNext = try mappedStart.addingWithoutOverflow(
                            UInt64(output.data.count)
                        )
                        try Self.yield(
                            MobileTerminalDataPlaneFrame(
                                kind: .chunk,
                                retainedBaseSequence: mappedStart,
                                sequence: mappedStart,
                                currentSequence: mappedNext,
                                data: output.data
                            ),
                            to: pair.continuation
                        )

                    case .replacement:
                        throw MobileTerminalDataPlaneError.generationChanged

                    case .colorsChanged:
                        break
                    }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
            // Normal EOF, overflow, cancellation, and source failure all retire
            // only this phone's dedicated daemon connection and client UUID.
            await session.close()
            await onClose()
        }
    }

    deinit { producer?.cancel() }

    func frames() async throws -> AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error> {
        guard !framesClaimed else {
            throw MobileTerminalDataPlaneError.streamAlreadyClaimed
        }
        framesClaimed = true
        return stream
    }

    func sendInput(_ text: String) async throws {
        try await session.sendInput(text)
    }

    func close() async {
        producer?.cancel()
        producer = nil
        await session.close()
        await onClose()
    }

    private nonisolated static func yield(
        _ frame: MobileTerminalDataPlaneFrame,
        to continuation: AsyncThrowingStream<MobileTerminalDataPlaneFrame, any Error>.Continuation
    ) throws {
        switch continuation.yield(frame) {
        case .enqueued:
            return
        case .dropped:
            throw MobileTerminalDataPlaneError.streamOverflow
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw MobileTerminalDataPlaneError.unavailable
        }
    }
}

private extension UUID {
    static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    var isNil: Bool {
        self == Self.nilUUID
    }
}

private extension UInt64 {
    func addingWithoutOverflow(_ value: UInt64) throws -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        guard !overflow else { throw MobileTerminalDataPlaneError.cursorGap }
        return result
    }
}
