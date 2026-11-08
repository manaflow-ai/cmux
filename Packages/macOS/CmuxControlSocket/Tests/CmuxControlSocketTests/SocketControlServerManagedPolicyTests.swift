@testable import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import Testing

@MainActor
@Suite("SocketControlServer managed policy", .timeLimit(.minutes(1)))
struct SocketControlServerManagedPolicyTests {
    @Test(arguments: [SocketControlMode.allowAll, .automation, .password])
    func reconfigureRevokesAcceptedAndAuthenticatedClients(previousMode: SocketControlMode) async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "fixture-password")
        defer { fixture.shutdown() }
        let server = fixture.server
        try #require(server.start(socketPath: fixture.socketPath, accessMode: previousMode))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try await server.connections.nextControlConnection()
        defer { close(connection.socket) }
        var authentication = SocketPasswordAuthorization()
        authentication.authenticate(password: "fixture-password")
        #expect(server.isConnectionAuthorizationCurrent(
            connection.authorizationGeneration, passwordAuthorization: authentication
        ))

        try #require(server.reconfigure(accessMode: .cmuxOnly))
        #expect(server.accessMode == .cmuxOnly)
        #expect(!server.isConnectionAuthorizationCurrent(
            connection.authorizationGeneration, passwordAuthorization: authentication
        ))
        var descriptor = pollfd(
            fd: connection.authorizationRevocationSignal.readFileDescriptor,
            events: Int16(POLLIN), revents: 0
        )
        #expect(poll(&descriptor, 1, 0) == 1)

        // A client captured under the new mode has a distinct, live generation.
        let nextClient = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(nextClient) }
        let next = try await server.connections.nextControlConnection()
        defer { close(next.socket) }
        #expect(next.authorizationGeneration != connection.authorizationGeneration)
        #expect(server.isConnectionAuthorizationCurrent(next.authorizationGeneration))
        try #require(server.reconfigure(accessMode: .off))
        #expect(server.accessMode == .off)
        #expect(!server.isRunning)
        #expect(!server.isConnectionAuthorizationCurrent(next.authorizationGeneration))
        #expect(throws: (any Error).self) {
            let unexpected = try UnixSocketFixture.connectClient(to: fixture.socketPath)
            close(unexpected)
        }
    }

    @Test func delayedReaderCannotRestorePolicyAfterRepeatedFlips() async throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }
        let server = fixture.server
        try #require(server.start(socketPath: fixture.socketPath, accessMode: .allowAll))
        let oldGeneration = server.connectionAuthorizationGeneration
        let ready = AsyncStream<SocketControlMode>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let reader = Task.detached {
            ready.continuation.yield(server.accessMode)
            var iterator = resume.stream.makeAsyncIterator()
            _ = await iterator.next()
            return (server.accessMode, server.isConnectionAuthorizationCurrent(oldGeneration))
        }
        defer {
            resume.continuation.finish()
            reader.cancel()
        }
        var readiness = ready.stream.makeAsyncIterator()
        #expect(await readiness.next() == .allowAll)
        for _ in 0..<8 {
            try #require(server.reconfigure(accessMode: .cmuxOnly))
            try #require(server.reconfigure(accessMode: .off))
            try #require(server.start(socketPath: fixture.socketPath, accessMode: .allowAll))
        }
        try #require(server.reconfigure(accessMode: .cmuxOnly))
        let enforcedGeneration = server.connectionAuthorizationGeneration
        resume.continuation.yield(())
        let observed = await reader.value
        #expect(observed.0 == .cmuxOnly)
        #expect(!observed.1)
        #expect(server.accessMode == .cmuxOnly)
        #expect(server.connectionAuthorizationGeneration == enforcedGeneration)
    }

    @Test func offTransitionInvalidatesItsNewGenerationBeforeListenerTeardown() {
        let authorization = SocketConnectionAuthorizationState()
        authorization.configure(accessMode: .password, effectivePassword: "fixture-password")
        authorization.setRunning(true)
        let previous = authorization.currentGeneration
        authorization.configure(accessMode: .off, effectivePassword: nil)
        let stopped = authorization.currentGeneration
        #expect(stopped.number != previous.number)
        #expect(!authorization.isCurrent(stopped.number))
        #expect(!authorization.permitsContinuation(
            generation: stopped.number, authenticatedPasswordFingerprint: nil
        ))
        authorization.configure(accessMode: .cmuxOnly, effectivePassword: nil)
        #expect(!authorization.isCurrent(authorization.currentGeneration.number))
        authorization.setRunning(true)
        #expect(authorization.isCurrent(authorization.currentGeneration.number))
        #expect(!authorization.isCurrent(previous.number))
    }

    @Test func idleSocketReadFinishesOnPolicyRevocation() async throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }
        let server = fixture.server
        try #require(server.start(socketPath: fixture.socketPath, accessMode: .allowAll))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try await server.connections.nextControlConnection()
        let reader = ControlClientAsyncLineReader(
            socket: connection.socket,
            authorizationRevocationSignal: connection.authorizationRevocationSignal
        )
        let reading = Task.detached {
            await reader.nextLine {
                server.isConnectionAuthorizationCurrent(connection.authorizationGeneration)
            }
        }
        try #require(server.reconfigure(accessMode: .cmuxOnly))
        #expect(await reading.value == nil)
        await reader.cancelAndWait()
        // The connection owns its fd; neither generation revocation nor the
        // reader may close it and accidentally affect a reused descriptor.
        #expect(fcntl(connection.socket, F_GETFD) >= 0)
        shutdown(connection.socket, SHUT_RDWR)
        close(connection.socket)
    }

    @Test func timeoutCancelsTheIdleStreamConsumer() async {
        let stream = AsyncStream<ControlConnection>.makeStream()
        defer { stream.continuation.finish() }
        await #expect(throws: SocketConnectionWaitError.self) {
            _ = try await stream.stream.nextControlConnection(timeout: .zero)
        }
        // Termination on cancellation is AsyncStream's documented contract.
        let result = stream.continuation.yield(ControlConnection(
            socket: -1, peerProcessID: nil, authorizationGeneration: 0
        ))
        if case .terminated = result {} else { Issue.record("iterator was not cancelled") }
    }
}
