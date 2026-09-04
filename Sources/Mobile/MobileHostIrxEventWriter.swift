import CmuxIrxTransport
import CmuxIrohTransport
import Foundation

/// Lazy server-events lane writer for the irx host connection.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private let clock: any CmxIrohRelayClock
    private let writeTimeout: TimeInterval
    private var writer: IrxStreamWriter?
    private var openingWriter: Task<IrxStreamWriter, any Error>?
    private var openingWriterID: UUID?
    private var closed = false

    init(
        connection: IrxConnection,
        journal: IrxJournal,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        writeTimeout: TimeInterval = 3
    ) {
        self.connection = connection
        self.journal = journal
        self.clock = clock
        self.writeTimeout = max(0.1, writeTimeout)
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await send(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        guard !closed else {
            throw MobileHostIrxEventWriterOpenError.closed
        }
        var supersededOpen = false
        while true {
            let writer: IrxStreamWriter
            do {
                writer = try await openedWriter()
            } catch let error as MobileHostIrxEventWriterOpenError {
                switch error {
                case .superseded:
                    // reset() can supersede an open after the QUIC lane has
                    // been created. The creator owns finishing that lane; one
                    // sender may immediately establish the replacement lane.
                    guard !supersededOpen else { throw CancellationError() }
                    supersededOpen = true
                    continue
                case .closed, .writeTimedOut:
                    // close() is terminal and a deadline is a completed
                    // failure. Neither condition may reopen this lane.
                    throw error
                }
            }
            do {
                try await sendWithDeadline(framedData, writer: writer)
                return
            } catch {
                // A failed QUIC lane cannot be reused. Drop it before
                // finishing so a reentrant sender opens a fresh lane on its
                // next attempt.
                if self.writer === writer {
                    self.writer = nil
                }
                await writer.reset(errorCode: 1)
                throw error
            }
        }
    }

    func reset() async {
        guard !closed else { return }
        openingWriter?.cancel()
        openingWriter = nil
        openingWriterID = nil
        let current = writer
        writer = nil
        await current?.finish()
        journal.record("host-events", "writer-reset")
    }

    func close() async {
        guard !closed else { return }
        // Set the terminal bit before any await. A sender that re-enters the
        // actor while the stream is finishing must fail closed, never reopen a
        // lane on this torn-down connection.
        closed = true
        openingWriter?.cancel()
        openingWriter = nil
        openingWriterID = nil
        let current = writer
        writer = nil
        await current?.finish()
        journal.record("host-events", "writer-closed")
    }

    private func openedWriter() async throws -> IrxStreamWriter {
        guard !closed else {
            throw MobileHostIrxEventWriterOpenError.closed
        }
        if let writer { return writer }
        if let openingWriter {
            let openingID = openingWriterID
            let opened = try await openingWriter.value
            guard !closed else {
                await opened.finish()
                throw MobileHostIrxEventWriterOpenError.closed
            }
            if let writer { return writer }
            guard let openingID, openingWriterID == openingID else {
                // The creator of the open owns cleanup. A follower must not
                // finish the same writer while the creator is still unwinding.
                throw MobileHostIrxEventWriterOpenError.superseded
            }
            self.openingWriter = nil
            self.openingWriterID = nil
            self.writer = opened
            journal.record("host-events", "writer-opened")
            return opened
        }
        let connection = connection
        let id = UUID()
        let task = Task<IrxStreamWriter, any Error> {
            let opened = try await connection.openUniLane(
                IrxLaneDescriptor(lane: .events)
            )
            try? await opened.setPriority(50)
            return opened
        }
        openingWriter = task
        openingWriterID = id
        do {
            let opened = try await task.value
            guard !closed else {
                await opened.finish()
                throw MobileHostIrxEventWriterOpenError.closed
            }
            // A reentrant follower may have completed this same open while
            // the creator was suspended. Reuse the writer it cached instead
            // of treating the completed open as superseded and finishing it.
            if let writer { return writer }
            guard openingWriterID == id else {
                await opened.finish()
                throw MobileHostIrxEventWriterOpenError.superseded
            }
            openingWriter = nil
            openingWriterID = nil
            writer = opened
            journal.record("host-events", "writer-opened")
            return opened
        } catch {
            if openingWriterID == id {
                openingWriter = nil
                openingWriterID = nil
            }
            throw error
        }
    }

    /// Bounds QUIC flow-control stalls so a peer that stopped reading cannot
    /// hold connection teardown indefinitely. The timeout resets this lane;
    /// the caller reports the failure and may retry through a fresh lane.
    private func sendWithDeadline(
        _ framedData: Data,
        writer: IrxStreamWriter
    ) async throws {
        let clock = clock
        let deadline = clock.now().addingTimeInterval(writeTimeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await writer.write(framedData)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                await writer.reset(errorCode: 1)
                throw MobileHostIrxEventWriterOpenError.writeTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MobileHostIrxEventWriterOpenError.writeTimedOut
            }
            return result
        }
    }
}
