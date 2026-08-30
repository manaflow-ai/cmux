import CmuxIrxTransport
import Foundation

/// Lazy server-events lane writer for the irx host connection.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private var writer: IrxStreamWriter?
    private var openingWriter: Task<IrxStreamWriter, any Error>?
    private var openingWriterID: UUID?

    init(connection: IrxConnection, journal: IrxJournal) {
        self.connection = connection
        self.journal = journal
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
        let writer = try await openedWriter()
        do {
            try await writer.write(framedData)
        } catch {
            // A failed QUIC lane cannot be reused. Drop it before finishing so
            // a reentrant sender opens a fresh lane on its next attempt.
            if self.writer === writer {
                self.writer = nil
            }
            await writer.finish()
            throw error
        }
    }

    func reset() async {
        openingWriter?.cancel()
        openingWriter = nil
        openingWriterID = nil
        if let writer {
            await writer.finish()
        }
        writer = nil
        journal.record("host-events", "writer-reset")
    }

    func close() async {
        openingWriter?.cancel()
        openingWriter = nil
        openingWriterID = nil
        if let writer {
            await writer.finish()
        }
        writer = nil
    }

    private func openedWriter() async throws -> IrxStreamWriter {
        if let writer { return writer }
        if let openingWriter {
            return try await openingWriter.value
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
            guard openingWriterID == id else {
                await opened.finish()
                throw CancellationError()
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
}
