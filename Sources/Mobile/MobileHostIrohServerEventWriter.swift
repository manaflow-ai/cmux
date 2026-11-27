import CMUXMobileCore
import CmuxIrohTransport
import Foundation

private enum MobileHostIrohServerEventWriterError: Error {
    case closed
    case superseded
    case concurrentSend
    case sendTimedOut
}

/// Owns one reusable `serverEvents` send stream. The host connection supplies
/// the bounded event queue; this writer rejects concurrent sends and bounds
/// QUIC flow-control stalls so the caller can immediately fall back to control.
actor MobileHostIrohServerEventWriter: MobileHostIndependentEventWriting {
    typealias StreamOpener = @Sendable () async throws -> any CmxIrohSendStream

    private struct PendingOpen: Sendable {
        let id: UUID
        let task: Task<any CmxIrohSendStream, any Error>
    }

    private static let priority: Int32 = 50
    private let openStream: StreamOpener
    private let clock: any CmxIrohRelayClock
    private let sendTimeout: TimeInterval
    private var pendingOpen: PendingOpen?
    private var stream: (any CmxIrohSendStream)?
    private var streamID: UUID?
    private var sendInFlight = false
    private var closed = false

    init(
        session: CmxIrohAdmittedServerSession,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        sendTimeout: TimeInterval = 3
    ) {
        openStream = {
            try await session.openSendLane(
                .serverEvents(cursor: nil),
                priority: Self.priority
            )
        }
        self.clock = clock
        self.sendTimeout = sendTimeout
    }

    init(
        openStream: @escaping StreamOpener,
        clock: any CmxIrohRelayClock,
        sendTimeout: TimeInterval
    ) {
        self.openStream = openStream
        self.clock = clock
        self.sendTimeout = sendTimeout
    }

    func prepare() async throws {
        guard !closed else { throw MobileHostIrohServerEventWriterError.closed }
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
                throw MobileHostIrohServerEventWriterError.superseded
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
            throw MobileHostIrohServerEventWriterError.concurrentSend
        }
        sendInFlight = true
        defer { sendInFlight = false }
        try await sendOnPreparedStream(framedData)
    }

    private func sendOnPreparedStream(_ framedData: Data) async throws {
        guard !closed, let activeStream = stream, let activeStreamID = streamID else {
            throw MobileHostIrohServerEventWriterError.closed
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
        stream: any CmxIrohSendStream
    ) async throws {
        let clock = clock
        let deadline = clock.now().addingTimeInterval(sendTimeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await stream.send(data)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                await stream.reset(errorCode: 1)
                throw MobileHostIrohServerEventWriterError.sendTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MobileHostIrohServerEventWriterError.superseded
            }
            return result
        }
    }
}
