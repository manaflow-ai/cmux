import CmuxIrxTransport
import Foundation

/// Lazy server-events lane writer for the irx host connection.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private enum WriterOpenError: Error {
        case superseded
    }

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
        var supersededOpen = false
        while true {
            let writer: IrxStreamWriter
            do {
                writer = try await openedWriter()
            } catch is WriterOpenError {
                // reset()/close() can supersede an open after the QUIC lane
                // has been created. The creator owns finishing that lane; one
                // sender may immediately establish the replacement lane.
                guard !supersededOpen else { throw CancellationError() }
                supersededOpen = true
                continue
            }
            do {
                try await writer.write(framedData)
                return
            } catch {
                // A failed QUIC lane cannot be reused. Drop it before
                // finishing so a reentrant sender opens a fresh lane on its
                // next attempt.
                if self.writer === writer {
                    self.writer = nil
                }
                await writer.finish()
                throw error
            }
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
            let openingID = openingWriterID
            let opened = try await openingWriter.value
            if let writer { return writer }
            guard let openingID, openingWriterID == openingID else {
                // The creator of the open owns cleanup. A follower must not
                // finish the same writer while the creator is still unwinding.
                throw WriterOpenError.superseded
            }
            openingWriter = nil
            openingWriterID = nil
            writer = opened
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
            // A reentrant follower may have completed this same open while
            // the creator was suspended. Reuse the writer it cached instead
            // of treating the completed open as superseded and finishing it.
            if let writer { return writer }
            guard openingWriterID == id else {
                await opened.finish()
                throw WriterOpenError.superseded
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
