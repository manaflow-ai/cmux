import CmuxNextIPC
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon connection's platform seams (p15-oracle-129): the folder watch ``RetryWake`` arms (a vnode
/// source on Darwin, inotify on Linux), the stream socket every daemon connection opens and its address. Each
/// test holds both platforms to what the Darwin code did before the seams. A watch that never calls its handler
/// fails by the suite's time limit; the tests never poll.
@Suite(.timeLimit(.minutes(1))) struct DaemonPlatformTransportTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-platform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Watches `folder`; the returned stream gets one element per handler call.
    private func watch(_ folder: URL) throws -> (FolderEventSource, AsyncStream<Void>) {
        let opened = try #require(FolderEventSource.Opened(path: folder.path))
        let (calls, continuation) = AsyncStream<Void>.makeStream()
        let source = FolderEventSource(opened, queue: DispatchQueue(label: "test.folder-events", qos: .utility)) {
            continuation.yield()
        }
        return (source, calls)
    }

    @Test func aFolderWatchSeesAnEntryMade() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, calls) = try watch(root)
        defer { source.cancel() }
        #expect(FileManager.default.createFile(atPath: root.appendingPathComponent("cmux.sock").path, contents: Data()))
        var iterator = calls.makeAsyncIterator()
        #expect(await iterator.next() != nil, "a new entry in the watched folder did not reach the handler")
    }

    @Test func aFolderWatchSeesAnEntryRemoved() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = root.appendingPathComponent("cmux.sock")
        #expect(FileManager.default.createFile(atPath: entry.path, contents: Data()))
        let (source, calls) = try watch(root)
        defer { source.cancel() }
        try FileManager.default.removeItem(at: entry)
        var iterator = calls.makeAsyncIterator()
        #expect(await iterator.next() != nil, "a removed entry did not reach the handler")
    }

    /// A daemon's ready marker is written beside the socket and renamed into place.
    @Test func aFolderWatchSeesAnEntryRenamedIn() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try scratch()
        defer { try? FileManager.default.removeItem(at: outside) }
        let made = outside.appendingPathComponent("ready.json")
        #expect(FileManager.default.createFile(atPath: made.path, contents: Data("{}".utf8)))
        let (source, calls) = try watch(root)
        defer { source.cancel() }
        try FileManager.default.moveItem(at: made, to: root.appendingPathComponent("ready.json"))
        var iterator = calls.makeAsyncIterator()
        #expect(await iterator.next() != nil, "an entry renamed into the watched folder did not reach the handler")
    }

    /// ``RetryWake`` moves its watch when the watched folder goes away.
    @Test func aFolderWatchSeesTheFolderRemoved() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let (source, calls) = try watch(folder)
        defer { source.cancel() }
        try FileManager.default.removeItem(at: folder)
        var iterator = calls.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the watched folder's own removal did not reach the handler")
    }

    @Test func aMissingFolderOrAFileDoesNotOpen() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderEventSource.Opened(path: root.appendingPathComponent("absent").path) == nil)
        let file = root.appendingPathComponent("file")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let opened = FolderEventSource.Opened(path: file.path)
        // Darwin's O_EVTONLY opens a file too; RetryWake only opens a path it saw as a folder. Linux refuses it.
        #if canImport(Darwin)
        opened?.discard()
        #else
        #expect(opened == nil)
        #endif
    }

    @Test func theStreamSocketIsCloseOnExec() throws {
        let fd = openUnixStreamSocket()
        try #require(fd >= 0)
        defer { closeSocket(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "a daemon connection would leak into the programs the app runs")
    }

    /// A send to a daemon that closed its end fails with EPIPE (the writer's `.peerClosed`) instead of raising
    /// SIGPIPE, whose default action would end the test process: SO_NOSIGPIPE on Darwin, MSG_NOSIGNAL on every
    /// send on both.
    @Test func aSendToAClosedDaemonFailsInsteadOfRaisingSIGPIPE() throws {
        // Under /tmp: Darwin's temporary folder leaves too little of sun_path's 104 bytes.
        let path = "/tmp/cmux-dp-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let address = try #require(UnixSocketAddress(path: path))
        let listener = openUnixStreamSocket()
        try #require(listener >= 0)
        defer { closeSocket(listener) }
        try #require(address.bind(listener) == 0)
        try #require(listen(listener, 1) == 0)
        let client = openUnixStreamSocket()
        try #require(client >= 0)
        defer { closeSocket(client) }
        try #require(address.connect(client) == 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        closeSocket(accepted)
        let sink = SocketFrameSink(fd: client)
        let bytes = [UInt8](repeating: 0x61, count: 64)
        var result: Result<Int, FrameWriter.Failure> = .success(0)
        // A send can still land in the socket buffer before the kernel sees the closed peer; a later one fails.
        for _ in 0..<4 {
            // SAFETY: send reads the array's own bytes, which the closure lends for the call only.
            result = unsafe bytes.withUnsafeBytes { unsafe sink.send($0, fds: []) }
            if case .failure = result { break }
        }
        #expect(result == .failure(.peerClosed))
    }

    @Test func anAddressFitsSunPathWithItsNUL() {
        let longest = String(repeating: "a", count: UnixSocketAddress.pathCapacity - 1)
        #expect(UnixSocketAddress(path: longest)?.path == longest)
        #expect(UnixSocketAddress(path: longest + "a") == nil)
    }
}
