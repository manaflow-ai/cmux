@testable import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation
import Testing

@MainActor
@Suite("SocketControlServer live configuration")
struct SocketControlServerConfigurationTests {
    @Test func reconfigurePublishesModeAndReappliesPermissionsWithoutRebinding() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .cmuxOnly))
        let originalIdentity = try #require(fixture.server.transport.pathIdentity(at: fixture.socketPath))
        #expect(try socketPermissions(at: fixture.socketPath) == 0o600)

        fixture.server.reconfigure(accessMode: .allowAll)

        #expect(fixture.server.isRunning)
        #expect(fixture.server.accessMode == .allowAll)
        #expect(fixture.server.transport.pathIdentity(at: fixture.socketPath) == originalIdentity)
        #expect(try socketPermissions(at: fixture.socketPath) == 0o666)
    }

    @Test func reconfigureOffStopsAndUnlinksListener() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))

        fixture.server.reconfigure(accessMode: .off)

        #expect(!fixture.server.isRunning)
        #expect(fixture.server.accessMode == .off)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    @Test func directStartWithOffLeavesNoListener() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(!fixture.server.start(socketPath: fixture.socketPath, accessMode: .off))
        #expect(!fixture.server.isRunning)
        #expect(fixture.server.accessMode == .off)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    @Test func reconfigureInvalidatesConnectionsAcceptedUnderPreviousMode() async throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .allowAll))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }
        let originalIdentity = try #require(fixture.server.transport.pathIdentity(at: fixture.socketPath))
        #expect(fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))

        #expect(fixture.server.reconfigure(accessMode: .automation))

        #expect(!fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
        #expect(fixture.server.transport.pathIdentity(at: fixture.socketPath) == originalIdentity)
    }

    @Test func offOnCycleDoesNotReauthorizeOldConnections() async throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }

        #expect(fixture.server.reconfigure(accessMode: .off))
        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))

        #expect(!fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
    }

    @Test func permissionFailureStopsListener() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .allowAll))
        #expect(unlink(fixture.socketPath) == 0)

        #expect(!fixture.server.reconfigure(accessMode: .automation))
        #expect(!fixture.server.isRunning)
    }

    @Test func configuredPreferredPathTracksConfigurationInsteadOfActiveFallback() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(!fixture.server.updateConfiguredPreferredSocketPath("/preferred/cmux.sock"))
        #expect(!fixture.server.updateConfiguredPreferredSocketPath("/preferred/cmux.sock"))
        #expect(fixture.server.updateConfiguredPreferredSocketPath("/other/cmux.sock"))
        #expect(!fixture.server.updateConfiguredPreferredSocketPath("/other/cmux.sock"))
    }

    @Test func firstPreferredPathDetectsDriftFromRunningListener() throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .cmuxOnly))
        let preferredPath = fixture.directory.appendingPathComponent("preferred.sock").path

        #expect(fixture.server.updateConfiguredPreferredSocketPath(preferredPath))
    }

    @Test func passwordChangeNotificationInvalidatesAcceptedConnections() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "original-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .password))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }
        #expect(fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))

        fixture.setEffectivePassword("rotated-secret")
        fixture.notificationCenter.post(
            name: SecretFileStore.didChangeNotification,
            object: nil,
            userInfo: [SecretFileStore.changedKeyIDKey: "automation.socketPassword"]
        )

        #expect(!fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
    }

    @Test func unrelatedSecretNotificationPreservesAcceptedConnections() async throws {
        let fixture = try SocketConfigurationFixture()
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .password))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }

        fixture.notificationCenter.post(
            name: SecretFileStore.didChangeNotification,
            object: nil,
            userInfo: [SecretFileStore.changedKeyIDKey: "unrelated.secret"]
        )

        #expect(fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
    }

    @Test func unchangedPasswordStoreNotificationPreservesAcceptedConnections() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "stable-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .password))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }

        fixture.notificationCenter.post(
            name: SocketControlPasswordStore.didChangeNotification,
            object: nil
        )

        #expect(fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
    }

    @Test func passwordNotificationOutsidePasswordModePreservesAcceptedConnections() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "original-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }

        fixture.setEffectivePassword("rotated-secret")
        fixture.notificationCenter.post(
            name: SocketControlPasswordStore.didChangeNotification,
            object: nil
        )

        #expect(fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration))
    }

    @Test func hotAuthorizationChecksDoNotReadPasswordProvider() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "original-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .password))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }
        var passwordAuthorization = SocketPasswordAuthorization()
        passwordAuthorization.authenticate(password: "original-secret")
        let readsAfterStart = fixture.passwordReadCount

        for _ in 0..<10 {
            #expect(fixture.server.isConnectionAuthorizationCurrent(
                connection.authorizationGeneration
            ))
            #expect(fixture.server.isConnectionAuthorizationCurrent(
                connection.authorizationGeneration,
                passwordAuthorization: passwordAuthorization
            ))
        }

        #expect(fixture.passwordReadCount == readsAfterStart)
    }

    @Test func nonPasswordChangeSignalsDoNotReadPasswordProvider() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "original-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .automation))
        let readsAfterStart = fixture.passwordReadCount
        fixture.notificationCenter.post(
            name: SocketControlPasswordStore.didChangeNotification,
            object: nil
        )
        fixture.notificationCenter.post(
            name: SecretFileStore.didChangeNotification,
            object: nil,
            userInfo: [SecretFileStore.changedKeyIDKey: "automation.socketPassword"]
        )
        await fixture.signalExternalPasswordChangeAndWaitUntilConsumed()

        #expect(fixture.passwordReadCount == readsAfterStart)
    }

    @Test func externalPasswordChangeSignalRevokesAcceptedConnection() async throws {
        let fixture = try SocketConfigurationFixture(effectivePassword: "original-secret")
        defer { fixture.shutdown() }

        #expect(fixture.server.start(socketPath: fixture.socketPath, accessMode: .password))
        let client = try UnixSocketFixture.connectClient(to: fixture.socketPath)
        defer { close(client) }
        let connection = try #require(await nextConnection(from: fixture.server.connections))
        defer { close(connection.socket) }

        fixture.setEffectivePassword("rotated-secret")
        await fixture.signalExternalPasswordChangeAndWaitUntilConsumed()

        #expect(await waitUntil {
            !fixture.server.isConnectionAuthorizationCurrent(connection.authorizationGeneration)
        })
    }

    private func socketPermissions(at path: String) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let raw = try #require(attributes[.posixPermissions] as? NSNumber)
        return raw.uint16Value
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

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
