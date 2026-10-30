import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// A pipe read that fails ends the stream instead of raising (cmuxterm-hq#4753): `availableData`
/// raises an Objective-C exception on EBADF or EIO, which Swift cannot catch, so a descriptor closed
/// under a live readability handler (Add Machine's Cancel stopping its run) aborted the app.
struct FileHandleReadReadyTests {
    @Test func readyBytesComeBack() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("enroll ok\n".utf8))
        #expect(pipe.fileHandleForReading.readReady() == .bytes(Data("enroll ok\n".utf8)))
    }

    @Test func endOfFileEndsTheStream() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        #expect(pipe.fileHandleForReading.readReady() == .end)
    }

    @Test func aClosedDescriptorEndsTheStreamWithoutRaising() throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { close(fds[1]) }
        // The read end goes away under the reader, as when a run is stopped mid-read: read(2) fails
        // with EBADF, where `availableData` would raise and abort the process.
        close(fds[0])
        let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        #expect(handle.readReady() == .end)
    }

    @Test func readyChunksGiveTheBytesThenEndAtEndOfFile() async throws {
        let pipe = Pipe()
        let reading = pipe.fileHandleForReading
        let (chunks, _) = reading.readyChunks()
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\ntwo\n".utf8))
        try pipe.fileHandleForWriting.close()
        var read = Data()
        for await chunk in chunks { read.append(chunk) }
        #expect(read == Data("one\ntwo\n".utf8))
        #expect(reading.readabilityHandler == nil)
    }

    /// A consumer that breaks out releases the stream, which ends it: the handler is cleared with
    /// no `stop()` call.
    @Test func aConsumerThatBreaksOutClearsTheHandler() async throws {
        let pipe = Pipe()
        let reading = pipe.fileHandleForReading
        try pipe.fileHandleForWriting.write(contentsOf: Data("a".utf8))
        let consumer = Task {
            let (chunks, _) = reading.readyChunks()
            for await _ in chunks { break }
        }
        await consumer.value
        #expect(reading.readabilityHandler == nil)
    }

    @Test func stopEndsTheStreamAndClearsTheHandler() async {
        let pipe = Pipe()
        let reading = pipe.fileHandleForReading
        let (chunks, stop) = reading.readyChunks()
        stop()
        for await _ in chunks { Issue.record("no chunk after stop") }
        #expect(reading.readabilityHandler == nil)
    }
}
