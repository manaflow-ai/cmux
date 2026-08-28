// Diagnostics behavior: dial-URL resolution provenance, and the connect
// lifecycle logging the phone's copyable connection report depends on.

import Foundation
import Testing
@testable import CmuxRelayTransport

@Suite struct RelayResolvedURLTests {
    @Test func envOverrideWins() {
        let resolved = RelayConnectAuth.resolvedRelayURL(
            environment: ["CMUX_MOBILE_RELAY_URL": "wss://example.test/v1/connect"]
        )
        #expect(resolved.url?.absoluteString == "wss://example.test/v1/connect")
        #expect(resolved.source.hasPrefix("env"))
    }

    @Test func debugBuildsDefaultToTheDevWorker() {
        let resolved = RelayConnectAuth.resolvedRelayURL(environment: [:])
        // Tests build Debug; the Release branch returns the production
        // constant and is exercised by release builds, not here.
        #expect(resolved.url?.absoluteString == RelayConnectAuth.debugDefaultRelayURLString)
        #expect(resolved.source.contains("debug-default"))
    }

    @Test func emptyEnvValueIsIgnored() {
        let resolved = RelayConnectAuth.resolvedRelayURL(
            environment: ["CMUX_MOBILE_RELAY_URL": ""]
        )
        #expect(resolved.url?.absoluteString == RelayConnectAuth.debugDefaultRelayURLString)
    }
}

/// Collects transport log lines across concurrency domains.
private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite struct RelayConnectLoggingTests {
    @Test func absentHostLogsDialWelcomeAndReason() async {
        let capture = LogCapture()
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 2, role: .client, sessionId: 7, deadline: (Date().timeIntervalSince1970 + 3600) * 1000, hostPresent: false)
        )
        let transport = RelayClientByteTransport(
            hostDeviceID: "host-1",
            deviceID: { "phone-1" },
            accessToken: { "stack-token-1" },
            makeConnection: { _, _ in fake },
            log: { capture.append($0) }
        )
        await #expect(throws: RelayTransportError.hostNotConnected) {
            try await transport.connect()
        }
        let lines = capture.lines
        #expect(lines.contains { $0.hasPrefix("relay.dial ") && $0.contains("host=host-1") })
        #expect(lines.contains { $0.hasPrefix("relay.welcome ") && $0.contains("hostPresent=false") })
        #expect(lines.contains { $0.hasPrefix("relay.host_absent") })
    }

    @Test func failedTokenIsLoggedBeforeAnyDial() async {
        struct TokenDead: Error {}
        let capture = LogCapture()
        let transport = RelayClientByteTransport(
            hostDeviceID: "host-1",
            deviceID: { "phone-1" },
            accessToken: { throw TokenDead() },
            makeConnection: { _, _ in
                Issue.record("must not dial without a token")
                return FakeRelayConnection(
                    welcome: RelayWelcome(v: 2, role: .client, sessionId: 1, deadline: 0, hostPresent: false)
                )
            },
            log: { capture.append($0) }
        )
        await #expect(throws: TokenDead.self) {
            try await transport.connect()
        }
        let lines = capture.lines
        #expect(lines.contains { $0.hasPrefix("relay.token_failed") })
        #expect(!lines.contains { $0.hasPrefix("relay.dial ") })
    }
}
