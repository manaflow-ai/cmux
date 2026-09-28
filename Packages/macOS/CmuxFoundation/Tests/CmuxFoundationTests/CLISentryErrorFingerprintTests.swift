import Testing
@testable import CmuxFoundation

@Suite struct CLISentryErrorFingerprintTests {
    private let fingerprint = CLISentryErrorFingerprint()

    @Test func classifiesKnownTransportFailures() {
        #expect(fingerprint.kind(forMessage: "Command timed out") == "command-timed-out")
        #expect(fingerprint.kind(forMessage: "Not connected") == "not-connected")
        #expect(fingerprint.kind(forMessage: "Socket read error") == "socket-read-error")
        #expect(fingerprint.kind(forMessage: "Socket not found at /tmp/cmux.sock") == "socket-not-found")
        #expect(fingerprint.kind(
            forMessage: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)"
        ) == "socket-connect-failed")
        #expect(fingerprint.kind(
            forMessage: "Failed to write to socket (Broken pipe, errno 32)"
        ) == "socket-write-failed")
        #expect(fingerprint.kind(forMessage: "Socket closed before reply") == "socket-closed-before-reply")
        #expect(fingerprint.kind(forMessage: "Socket closed before complete reply") == "socket-closed-before-reply")
    }

    /// A socket-connect `EPERM` is an OS policy denial of the calling process
    /// (Sentry CMUXTERM-MACOS-3JHJ). It groups on its own and is throttled so
    /// a denied agent-hook loop reports once per window, not once per hook.
    @Test func classifiesSocketConnectPolicyDenialAsThrottled() {
        let kind = fingerprint.kind(
            forMessage: "Failed to connect to socket at /tmp/cmux.sock (Operation not permitted, errno 1)"
        )
        #expect(kind == "socket-connect-denied")
        #expect(kind.map(CLISentryErrorFingerprint.throttledKinds.contains) == true)
        #expect(fingerprint.kind(
            forMessage: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)"
        ) == "socket-connect-failed")
        #expect(fingerprint.kind(
            forMessage: "Failed to connect to socket at /tmp/cmux.sock (Timed out, errno 10)"
        ) == "socket-connect-failed")
    }

    @Test func unknownMessagesKeepDefaultGrouping() {
        #expect(fingerprint.kind(forMessage: "Missing relay auth metadata") == nil)
        #expect(fingerprint.kind(forMessage: "Server reports peer not connected") == nil)
        #expect(fingerprint.kind(forMessage: "") == nil)
    }
}
