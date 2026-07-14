@testable import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

@Suite("Socket password authorization")
struct SocketPasswordAuthorizationTests {
    @Test func externalPasswordFileRotationRevokesCommandCapability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-\(UUID().uuidString)", isDirectory: true)
        let passwordURL = directory.appendingPathComponent("socket-password")
        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: passwordURL
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try passwordStore.savePassword("original-secret")
        var authorization = SocketPasswordAuthorization()
        authorization.authenticate(password: "original-secret")
        #expect(authorization.permitsConnectionContinuation(
            accessMode: .password,
            currentPassword: passwordStore.configuredPassword()
        ))

        try Data("rotated-secret\n".utf8).write(to: passwordURL, options: .atomic)

        #expect(!authorization.permitsConnectionContinuation(
            accessMode: .password,
            currentPassword: passwordStore.configuredPassword()
        ))
        #expect(authorization.permitsConnectionContinuation(
            accessMode: .automation,
            currentPassword: passwordStore.configuredPassword()
        ))
    }

    @Test func externalPasswordFileRotationRevokesEventStreamCapability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spas-\(UUID().uuidString)", isDirectory: true)
        let passwordURL = directory.appendingPathComponent("socket-password")
        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: passwordURL
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try passwordStore.savePassword("stream-secret")
        var authorization = SocketPasswordAuthorization()
        authorization.authenticate(password: "stream-secret")
        #expect(authorization.permitsConnectionContinuation(
            accessMode: .password,
            currentPassword: passwordStore.configuredPassword()
        ))

        try Data("rotated-stream-secret\n".utf8).write(to: passwordURL, options: .atomic)

        #expect(!authorization.permitsConnectionContinuation(
            accessMode: .password,
            currentPassword: passwordStore.configuredPassword()
        ))
    }

    @Test func credentialChecksAreCoalescedAndDetectTheNextRevision() {
        var authorization = SocketPasswordAuthorization()
        authorization.authenticate(password: "stream-secret")
        var passwordReads = 0

        let initialContinuation = authorization.permitsConnectionContinuation(
            accessMode: .password,
            monotonicNowNanoseconds: 100,
            minimumCredentialRefreshIntervalNanoseconds: 10,
            currentPassword: {
                passwordReads += 1
                return "stream-secret"
            }
        )
        #expect(initialContinuation)
        #expect(passwordReads == 1)

        let coalescedContinuation = authorization.permitsConnectionContinuation(
            accessMode: .password,
            monotonicNowNanoseconds: 109,
            minimumCredentialRefreshIntervalNanoseconds: 10,
            currentPassword: {
                passwordReads += 1
                return "rotated-secret"
            }
        )
        #expect(coalescedContinuation)
        #expect(passwordReads == 1)

        let rotatedContinuation = authorization.permitsConnectionContinuation(
            accessMode: .password,
            monotonicNowNanoseconds: 110,
            minimumCredentialRefreshIntervalNanoseconds: 10,
            currentPassword: {
                passwordReads += 1
                return "rotated-secret"
            }
        )
        #expect(!rotatedContinuation)
        #expect(passwordReads == 2)
    }

    @Test func unauthenticatedCapabilityMayAttemptLogin() {
        let authorization = SocketPasswordAuthorization()

        #expect(authorization.permitsConnectionContinuation(
            accessMode: .password,
            currentPassword: "configured-secret"
        ))
        #expect(!authorization.isAuthenticated)
    }
}
