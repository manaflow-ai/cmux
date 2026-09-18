import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import os
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
        let resolvedMode = OSAllocatedUnfairLock(initialState: SocketControlMode.allowAll)
        let server = SocketControlServer(
            initialSocketPath: path,
            notificationCenter: NotificationCenter(),
            effectiveAccessModeProvider: { resolvedMode.withLock { $0 } },
            events: events
        )
        defer { server.stop() }
        #expect(server.start(socketPath: path, accessMode: .allowAll))

        let fd = try UnixSocketFixture.connectClient(to: path)
        defer { close(fd) }
        let connection = try #require(await server.connections.nextControlConnection(), "server did not yield the accepted connection")
        let generation = connection.authorizationGeneration
        let signal = connection.authorizationRevocationSignal
        #expect(server.isConnectionAuthorizationCurrent(generation))

        resolvedMode.withLock { $0 = .cmuxOnly }
        #expect(server.reconfigure(accessMode: .cmuxOnly))
        #expect(server.accessMode == .cmuxOnly)
        #expect(!server.isConnectionAuthorizationCurrent(generation))
        var descriptor = pollfd(fd: signal.readFileDescriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 0) == 1)

        #expect(server.reconfigure(accessMode: .off))
        #expect(!server.isRunning)
        #expect(!server.isConnectionAuthorizationCurrent(generation))
    }

}
