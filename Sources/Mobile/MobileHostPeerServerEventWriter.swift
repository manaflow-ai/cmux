import CMUXMobileCore
import CmuxPeerTransport
import Foundation

private enum MobileHostPeerServerEventWriterError: Error {
    case closed
    case superseded
    case concurrentSend
    case sendTimedOut
}

/// The minimal send surface the event writer needs from a peer byte stream.
/// Tests fake this; production uses `PeerByteStream` directly.
protocol MobileHostPeerEventStreamWriting: Sendable {
    func write(_ data: Data) async throws
    func reset(errorCode: UInt64) async
}

extension PeerByteStream: MobileHostPeerEventStreamWriting {}

/// Owns one reusable host→client server-event lane on a `PeerHostSession`.
/// The host connection supplies the bounded event queue; this writer rejects
/// concurrent sends and bounds QUIC flow-control stalls (3s deadline) so the
/// caller can immediately fall back to control.
actor MobileHostPeerServerEventWriter: MobileHostIndependentEventWriting {
    typealias StreamOpener = @Sendable () async throws -> any MobileHostPeerEventStreamWriting
    typealias TimeoutSleep = @Sendable (Duration) async throws -> Void

    private struct PendingOpen: Sendable {
        let id: UUID
        let task: Task<any MobileHostPeerEventStreamWriting, any Error>
    }

    private let openStream: StreamOpener
    private let timeoutSleep: TimeoutSleep
    private let sendTimeout: Duration
    private var pendingOpen: PendingOpen?
    private var stream: (any MobileHostPeerEventStreamWriting)?
    private var streamID: UUID?
    private var sendInFlight = false
    private var closed = false

    init(
        session: PeerHostSession,
        sendTimeout: Duration = .seconds(3)
    ) {
        openStream = {
            try await session.openServerEventLane(cursor: nil)
        }
        timeoutSleep = { try await ContinuousClock().sleep(for: $0) }
        self.sendTimeout = sendTimeout
    }

    init(
        openStream: @escaping StreamOpener,
        timeoutSleep: @escaping TimeoutSleep = {
            try await ContinuousClock().sleep(for: $0)
        },
        sendTimeout: Duration = .seconds(3)
    ) {
        self.openStream = openStream
        self.timeoutSleep = timeoutSleep
        self.sendTimeout = sendTimeout
    }

    func prepare() async throws {
        guard !closed else { throw MobileHostPeerServerEventWriterError.closed }
        if stream != nil { return }

        let pending: PendingOpen
        if let pendingOpen {
            pending = pendingOpen
        } else {
            let openStream = openStream
            let task = Task {
                try await openStream()
            }
            pending = PendingOpen(id: UUID(), task: task)
            pendingOpen = pending
        }

        do {
            let opened = try await pending.task.value
            if stream != nil { return }
            guard pendingOpen?.id == pending.id, !closed else {
                await opened.reset(errorCode: 1)
                throw MobileHostPeerServerEventWriterError.superseded
            }
            pendingOpen = nil
            stream = opened
            streamID = UUID()
        } catch {
            if pendingOpen?.id == pending.id {
                pendingOpen = nil
            }
            throw error
        }
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await prepare()
            if sendInFlight { return true }
            sendInFlight = true
            defer { sendInFlight = false }
            try await sendOnPreparedStream(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        try await prepare()
        guard !sendInFlight else {
            throw MobileHostPeerServerEventWriterError.concurrentSend
        }
        sendInFlight = true
        defer { sendInFlight = false }
        try await sendOnPreparedStream(framedData)
    }

    private func sendOnPreparedStream(_ framedData: Data) async throws {
        guard !closed, let activeStream = stream, let activeStreamID = streamID else {
            throw MobileHostPeerServerEventWriterError.closed
        }
        do {
            try await sendWithDeadline(framedData, stream: activeStream)
        } catch {
            if streamID == activeStreamID {
                stream = nil
                streamID = nil
            }
            await activeStream.reset(errorCode: 1)
            throw error
        }
    }

    func reset() async {
        pendingOpen?.task.cancel()
        pendingOpen = nil
        let previous = stream
        stream = nil
        streamID = nil
        await previous?.reset(errorCode: 1)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        pendingOpen?.task.cancel()
        pendingOpen = nil
        let previous = stream
        stream = nil
        streamID = nil
        await previous?.reset(errorCode: 0)
    }

    private func sendWithDeadline(
        _ data: Data,
        stream: any MobileHostPeerEventStreamWriting
    ) async throws {
        let timeoutSleep = timeoutSleep
        let sendTimeout = sendTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await stream.write(data)
            }
            group.addTask {
                try await timeoutSleep(sendTimeout)
                await stream.reset(errorCode: 1)
                throw MobileHostPeerServerEventWriterError.sendTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MobileHostPeerServerEventWriterError.superseded
            }
            return result
        }
    }
}
