@testable import CmuxControlSocket
import Darwin
import Foundation
import Testing

@MainActor
@Suite("Socket capability rebind")
struct SocketCapabilityRebindTests {
    @Test func inheritedCapabilitySurvivesListenerRestartAndReparenting() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cap-rebind-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let server = SocketControlServer(
            initialSocketPath: socketPath,
            events: SocketControlServerEvents(
                breadcrumb: { _, _ in },
                failure: { _, _, _, _ in },
                listenerDidStart: { _, _ in },
                recordLastSocketPath: { _ in },
                pathMissingDetected: { _, _ in },
                rearmRequested: { _, _, _, _ in }
            )
        )
        defer { server.stop() }

        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0x11, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.cmuxterm.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x22, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))

        #expect(server.start(socketPath: socketPath, accessMode: .cmuxOnly))
        let firstClient = connect(to: socketPath)
        #expect(firstClient >= 0)
        let firstConnection = try #require(await nextConnection(from: server.connections))
        close(firstClient)
        close(firstConnection.socket)

        server.stop()
        #expect(server.start(socketPath: socketPath, accessMode: .cmuxOnly))
        let reboundClient = connect(to: socketPath)
        #expect(reboundClient >= 0)
        let reboundConnection = try #require(await nextConnection(from: server.connections))
        defer {
            close(reboundClient)
            close(reboundConnection.socket)
        }

        let command = "hooks claude prompt-submit"
        let authorized = SocketClientAuthorization().authorizedCommand(
            envelope.wrap(command),
            peerProcessID: reboundConnection.peerProcessID,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        )
        #expect(authorized == command)
    }

    private func connect(to path: String) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { source -> Bool in
            let length = strlen(source)
            guard length < MemoryLayout.size(ofValue: address.sun_path) else { return false }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.baseAddress?.copyMemory(from: source, byteCount: length + 1)
            }
            return true
        }
        guard copied else {
            close(descriptor)
            return -1
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    private func nextConnection(
        from stream: AsyncStream<ControlConnection>
    ) async -> ControlConnection? {
        await withTaskGroup(of: ControlConnection?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let connection = await group.next() ?? nil
            group.cancelAll()
            return connection
        }
    }
}
