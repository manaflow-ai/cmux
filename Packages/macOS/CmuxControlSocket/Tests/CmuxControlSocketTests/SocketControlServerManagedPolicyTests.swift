import CmuxControlSocket
import Darwin
import Foundation
import Testing

@MainActor
@Suite("SocketControlServer managed policy")
struct SocketControlServerManagedPolicyTests {
    @Test func reconfigureRevokesOldClientsBeforeApplyingNewMode() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scs-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let events = SocketControlServerEvents(
            breadcrumb: { _, _ in },
            failure: { _, _, _, _ in },
            listenerDidStart: { _, _ in },
            recordLastSocketPath: { _ in },
            pathMissingDetected: { _, _ in },
            rearmRequested: { _, _, _, _ in }
        )
        let server = SocketControlServer(
            initialSocketPath: path,
            notificationCenter: NotificationCenter(),
            events: events
        )
        defer { server.stop() }
        #expect(server.start(socketPath: path, accessMode: .allowAll))

        let fd = Self.connect(to: path)
        try #require(fd >= 0, "could not connect to test socket")
        defer { if fd >= 0 { close(fd) } }
        let connection = try #require(await Self.nextConnection(from: server.connections), "server did not yield the accepted connection")
        let generation = connection.authorizationGeneration
        let signal = connection.authorizationRevocationSignal
        #expect(server.isConnectionAuthorizationCurrent(generation))

        #expect(server.reconfigure(accessMode: .cmuxOnly))
        #expect(server.accessMode == .cmuxOnly)
        #expect(!server.isConnectionAuthorizationCurrent(generation))
        var descriptor = pollfd(fd: signal.readFileDescriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 0) == 1)

        #expect(server.reconfigure(accessMode: .off))
        #expect(!server.isRunning)
    }

    private static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { cString in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                let length = strlen(cString)
                guard length < buffer.count else { return false }
                buffer.baseAddress?.copyMemory(from: cString, byteCount: length + 1)
                return true
            }
        }
        guard copied else { close(fd); return -1 }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    private static func nextConnection(
        from stream: AsyncStream<ControlConnection>
    ) async -> ControlConnection? {
        await withTaskGroup(of: ControlConnection?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let connection = await group.next() ?? nil
            group.cancelAll()
            return connection
        }
    }
}
