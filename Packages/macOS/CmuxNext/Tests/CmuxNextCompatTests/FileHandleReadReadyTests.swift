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
}
