import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("FileHandle process-pipe reading")
struct FileHandleProcessPipeReadingTests {
    @Test("readAvailableData reports wouldBlock on an empty pipe with an open writer")
    func wouldBlockWhenWriterOpenAndEmpty() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        // The poll-before-read contract means this must not block even though
        // the descriptor itself is blocking (the original crash regression).
        let result = pipe.fileHandleForReading.readAvailableData()
        #expect(result == .success(.wouldBlock))
    }

    @Test("readAvailableData reports endOfFile when the writer is closed")
    func endOfFileWhenWriterClosed() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }

        let result = pipe.fileHandleForReading.readAvailableData()
        #expect(result == .success(.endOfFile))
    }

    @Test("readAvailableData returns buffered bytes")
    func returnsBufferedBytes() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))

        let result = pipe.fileHandleForReading.readAvailableData()
        #expect(result == .success(.data(Data("hello".utf8))))
    }

    @Test("readToEndOfFile preserves partial data when a later read fails")
    func partialDataPreservedOnFailure() {
        let partialData = Data("partial output".utf8)
        let readError = ProcessPipeReadError(
            operation: "readDataToEndOfFile",
            errnoCode: EIO
        )
        var reads: [Result<Data, ProcessPipeReadError>] = [
            .success(partialData),
            .failure(readError),
        ]

        let result = ProcessPipeEndRead.reading(
            fileDescriptor: -1,
            chunkSize: partialData.count
        ) { _, _, _ in
            reads.removeFirst()
        }

        #expect(result.data == partialData)
        #expect(result.readError == readError)
    }

    @Test("A stopped end read drains buffered bytes without waiting for EOF")
    func stoppedEndReadDrainsBufferedBytesWithoutEOF() throws {
        let pipe = Pipe()
        let stopSignal = try ProcessPipeStopSignal()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("buffered".utf8))
        stopSignal.signal()

        let result = ProcessPipeStopAwareReader(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            stopFileDescriptor: stopSignal.readFileDescriptor
        ).readToEnd()

        #expect(result.data == Data("buffered".utf8))
        #expect(result.readError == nil)
    }

    @Test("A stopped end read drains every byte present at the stop snapshot")
    func stoppedEndReadDrainsSnapshotLargerThanSixteenChunks() throws {
        let pipe = Pipe()
        let stopSignal = try ProcessPipeStopSignal()
        let payload = Data((0..<128).map { UInt8($0) })
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        stopSignal.signal()

        let result = ProcessPipeStopAwareReader(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            chunkSize: 1,
            stopFileDescriptor: stopSignal.readFileDescriptor
        ).readToEnd()

        #expect(result.data == payload)
        #expect(result.readError == nil)
    }

    @Test(
        "A non-positive chunk size still drains the stopped snapshot",
        arguments: [0, -1]
    )
    func nonPositiveChunkSizeDrainsStoppedSnapshot(
        chunkSize: Int
    ) throws {
        let pipe = Pipe()
        let stopSignal = try ProcessPipeStopSignal()
        let payload = Data("buffered".utf8)
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        stopSignal.signal()

        let result = ProcessPipeStopAwareReader(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            chunkSize: chunkSize,
            stopFileDescriptor: stopSignal.readFileDescriptor
        ).readToEnd()

        #expect(result.data == payload)
        #expect(result.readError == nil)
    }

    @Test("One stop signal wakes every blocked pipe reader")
    func stopSignalBroadcastsToBlockedReaders() throws {
        let firstPipe = Pipe()
        let secondPipe = Pipe()
        let stopSignal = try ProcessPipeStopSignal()
        defer {
            try? firstPipe.fileHandleForWriting.close()
            try? firstPipe.fileHandleForReading.close()
            try? secondPipe.fileHandleForWriting.close()
            try? secondPipe.fileHandleForReading.close()
        }

        stopSignal.signal()
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = ProcessPipeStopAwareReader(
                fileDescriptor: firstPipe.fileHandleForReading.fileDescriptor,
                stopFileDescriptor: stopSignal.readFileDescriptor
            ).readToEnd()
            firstFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            _ = ProcessPipeStopAwareReader(
                fileDescriptor: secondPipe.fileHandleForReading.fileDescriptor,
                stopFileDescriptor: stopSignal.readFileDescriptor
            ).readToEnd()
            secondFinished.signal()
        }

        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test("readDataToEndOfFileOrEmpty drains a closed pipe")
    func drainsClosedPipe() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("payload".utf8))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }

        #expect(pipe.fileHandleForReading.readDataToEndOfFileOrEmpty() == Data("payload".utf8))
    }

    @Test("copyDataToEndOfFile streams every byte")
    func copiesAllBytes() throws {
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data("copied bytes".utf8))
        try input.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
        }

        try input.fileHandleForReading.copyDataToEndOfFile(to: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()

        #expect(output.fileHandleForReading.readDataToEndOfFileOrEmpty() == Data("copied bytes".utf8))
    }
}
