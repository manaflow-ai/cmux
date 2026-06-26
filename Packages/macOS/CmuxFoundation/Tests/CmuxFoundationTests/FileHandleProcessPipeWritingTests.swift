import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("FileHandle process-pipe writing")
struct FileHandleProcessPipeWritingTests {
    @Test("writeIgnoringBrokenPipe delivers every byte to an open pipe")
    func deliversBytesToOpenPipe() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }

        let payload = Data("hello pipe".utf8)
        let outcome = pipe.fileHandleForWriting.writeIgnoringBrokenPipe(payload)
        try pipe.fileHandleForWriting.close()

        #expect(outcome == .completed)
        #expect(pipe.fileHandleForReading.readDataToEndOfFileOrEmpty() == payload)
    }

    @Test("writeIgnoringBrokenPipe reports brokenPipe when the reader is closed")
    func reportsBrokenPipeWhenReaderClosed() throws {
        let pipe = Pipe()
        // Closing the read end makes any write to the write end fault with EPIPE.
        // Foundation's FileHandle.write(_:) would raise an NSException (SIGABRT)
        // here; the helper must return .brokenPipe without crashing.
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }

        let outcome = pipe.fileHandleForWriting.writeIgnoringBrokenPipe(Data("dropped".utf8))
        #expect(outcome == .brokenPipe)
    }

    @Test("writeIgnoringBrokenPipe treats empty data as completed")
    func emptyDataCompletes() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        #expect(pipe.fileHandleForWriting.writeIgnoringBrokenPipe(Data()) == .completed)
    }
}
