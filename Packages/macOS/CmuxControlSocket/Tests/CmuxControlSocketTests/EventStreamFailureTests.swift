import Testing
@testable import CmuxControlSocket

/// Regression coverage for #12756's reconnect decision, hosted here so the
/// policy can be unit-tested without the CLI target: a typed
/// receive-timeout configuration failure is a transport-level transient, and
/// the reconnect loop must survive it instead of exiting with
/// `Failed to configure socket receive timeout (Invalid argument, errno 22)`.
@Suite("Event stream reconnect policy")
struct EventStreamFailureTests {
    @Test func receiveTimeoutConfigurationFailureIsTransient() {
        #expect(EventStreamFailure(
            socketFailureKind: .receiveTimeoutConfiguration,
            message: "Failed to configure socket receive timeout (Invalid argument, errno 22)"
        ).isTransient)
    }

    @Test func typedKindSurvivesUntypedLookingMessage() {
        // The typed kind is authoritative: even a message that no longer
        // carries the legacy markers must stay transient once the producer
        // classified the failure as a receive-timeout configuration issue.
        #expect(EventStreamFailure(
            socketFailureKind: .receiveTimeoutConfiguration,
            message: ""
        ).isTransient)
    }

    @Test func eventContentMentioningErrnoTextStaysFatal() {
        // Event *content* that happens to contain timeout-flavored text must
        // never classify a protocol frame as transient: a malformed frame is a
        // protocol error and --reconnect must not retry it forever.
        #expect(!EventStreamFailure(
            message:
                "Invalid event stream frame: {\"text\":\"failed to configure socket receive timeout (Invalid argument, errno 22)\"}"
        ).isTransient)
    }

    @Test func permanentProtocolErrorsStayFatal() {
        #expect(!EventStreamFailure(
            message: "Invalid event stream frame: not json"
        ).isTransient)
    }

    @Test func legacyConnectionMarkersStayTransient() {
        for message in [
            "socket not found",
            "event stream socket read error",
            "connection reset by peer",
            "connection refused",
            "broken pipe",
            "errno 54"
        ] {
            #expect(EventStreamFailure(message: message).isTransient)
        }
        #expect(!EventStreamFailure(message: "Invalid event stream frame").isTransient)
    }

    @Test func untypedFallbackDescriptionStillClassified() {
        #expect(EventStreamFailure(
            message: "",
            untypedDescription: "POSIXErrorCode(rawValue: 54): Connection reset by peer"
        ).isTransient)
        #expect(!EventStreamFailure(
            message: "",
            untypedDescription: "Invalid event stream frame: not json"
        ).isTransient)
    }
}
