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

    @Test func unknownMessagesKeepDefaultGrouping() {
        #expect(fingerprint.kind(forMessage: "Missing relay auth metadata") == nil)
        #expect(fingerprint.kind(forMessage: "Server reports peer not connected") == nil)
        #expect(fingerprint.kind(forMessage: "") == nil)
    }
}
