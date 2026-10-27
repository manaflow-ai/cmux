import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// ``FileHandle/readAvailable(upToCount:fileID:line:)`` replaces the legacy FileHandle read in every child-process
/// reader (p10-stability-168): a failed `read(2)` answers ``FileHandle/AvailableReadEnd/failed(errno:)`` where the
/// legacy read raised `NSFileHandleOperationException`, which no Swift `catch` stops.
@Suite(.serialized)
struct FileHandleAvailableReadTests {
    @Test func bytesThenTheEndOfAClosedPipe() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(pipe.fileHandleForReading.readAvailable() == .bytes(Data("hello".utf8)))
        #expect(pipe.fileHandleForReading.readAvailable() == .end(.endOfFile))
    }

    @Test func oneReadTakesAtMostTheCountAndLeavesTheRest() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("0123456789".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(pipe.fileHandleForReading.readAvailable(upToCount: 4) == .bytes(Data("0123".utf8)))
        // A count below 1 reads 1.
        #expect(pipe.fileHandleForReading.readAvailable(upToCount: 0) == .bytes(Data("4".utf8)))
        #expect(pipe.fileHandleForReading.readAvailable() == .bytes(Data("56789".utf8)))
    }

    /// The case the legacy read raised on: `read(2)` fails. A write-only descriptor fails with EBADF every time,
    /// with no race against another test reusing a closed descriptor number.
    @Test func anUnreadableDescriptorAnswersItsErrnoInsteadOfRaising() throws {
        let descriptor = open("/dev/null", O_WRONLY)
        try #require(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        #expect(handle.readAvailable() == .end(.failed(errno: EBADF)))
    }

    /// Chaos: the child is SIGKILLed while it writes. The readability handler sees its bytes and then the end of
    /// the stream, never an exception, and the handler is cleared on the end as the production readers do.
    @Test func aChildKilledDuringOutputEndsTheStream() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do printf '0123456789abcdef0123456789abcdef'; done"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let (reads, sink) = AsyncStream.makeStream(of: FileHandle.AvailableRead.self, bufferingPolicy: .unbounded)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let read = handle.readAvailable()
            sink.yield(read)
            if case .end = read {
                handle.readabilityHandler = nil
                sink.finish()
            }
        }
        try process.run()
        var bytes = 0
        var killed = false
        var last: FileHandle.AvailableRead?
        for await read in reads {
            last = read
            guard case .bytes(let data) = read else { break }
            #expect(!data.isEmpty, "bytes are never empty; the end is its own case")
            bytes += data.count
            if !killed, bytes >= 4096 {
                killed = true
                kill(process.processIdentifier, SIGKILL)
            }
        }
        #expect(killed, "the child wrote before it was killed")
        #expect(last == FileHandle.AvailableRead.end(.endOfFile), "the kill closes the pipe's only writer")
    }
}
