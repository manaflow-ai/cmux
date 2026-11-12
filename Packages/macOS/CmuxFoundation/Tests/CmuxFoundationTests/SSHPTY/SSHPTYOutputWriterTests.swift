import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

// Signal dispositions belong to the process; these ownership tests run serially.
@Suite(.serialized)
struct SSHPTYOutputWriterTests {
    @Test
    func outputPreservesBytesAndRestoresDescriptorFlags() throws {
        let pipe = Pipe()
        var bridge = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &bridge) == 0)
        defer { Darwin.close(bridge[0]); Darwin.close(bridge[1]) }
        let flags = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL)
        let monitor = try SSHPTYAttachSignalMonitor(bridgeFD: bridge[0])
        defer { monitor.cancel() }
        var writer: SSHPTYOutputWriter? = try SSHPTYOutputWriter(fileDescriptor: pipe.fileHandleForWriting.fileDescriptor)
        let bytes = Data("你好🙂\nraw bytes".utf8)
        #expect(writer?.write(bytes, cancellation: monitor) == true)
        #expect(pipe.fileHandleForReading.readData(ofLength: bytes.count) == bytes)
        writer = nil
        // Darwin adds the kernel's FWASWRITTEN status after any pipe write;
        // compare the caller-controlled flags, not that historical status bit.
        let restoredFlags = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFL)
        #expect(restoredFlags & (O_NONBLOCK | O_APPEND | O_ASYNC) == flags & (O_NONBLOCK | O_APPEND | O_ASYNC))
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 0)
    }

    @Test
    func repeatedCancellationRestoresSignalDisposition() throws {
        var bridge = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &bridge) == 0)
        defer { Darwin.close(bridge[0]); Darwin.close(bridge[1]) }
        var original = sigaction()
        try #require(sigaction(SIGTERM, nil, &original) == 0)
        let monitor = try SSHPTYAttachSignalMonitor(bridgeFD: bridge[0])
        monitor.cancel()
        monitor.cancel()
        var restored = sigaction()
        try #require(sigaction(SIGTERM, nil, &restored) == 0)
        #expect(restored.sa_flags == original.sa_flags)
        #expect(restored.sa_mask == original.sa_mask)
        let restoredHandler = unsafeBitCast(restored.__sigaction_u.__sa_handler, to: UInt.self)
        let originalHandler = unsafeBitCast(original.__sigaction_u.__sa_handler, to: UInt.self)
        #expect(restoredHandler == originalHandler)
    }
}
