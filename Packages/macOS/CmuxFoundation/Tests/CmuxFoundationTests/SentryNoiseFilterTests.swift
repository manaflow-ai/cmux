import Testing
@testable import CmuxFoundation

@Suite struct SentryNoiseFilterTests {
    private let filter = SentryNoiseFilter()

    @Test func dropsExpectedCLISocketDisconnectsInSocketStages() {
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "CLIError: Failed to write to socket (Broken pipe, errno 32) (Code: 1)"
        ))
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command_surface_list",
            message: "Failed to write to socket (Connection reset by peer, errno 54)"
        ))
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)"
        ))
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Socket not found at /tmp/cmux.sock"
        ))
    }

    @Test func keepsActionableSocketFailures() {
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Operation timed out, errno 60)"
        ))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Permission denied, errno 13)"
        ))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Operation not permitted, errno 1)"
        ))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "codex-monitor-start",
            message: "Failed to connect to socket at /tmp/cmux.sock (Operation not permitted, errno 1)",
            allowSandboxPolicyDenial: true
        ))
    }

    @Test func dropsSocketPolicyDenialOnlyWithSandboxProvenance() {
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Operation not permitted, errno 1)",
            allowSandboxPolicyDenial: true
        ))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Operation not permitted, errno 1)"
        ))
    }

    @Test func errnoMatchingRequiresExactCode() {
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Invalid argument, errno 22)"
        ))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Not a socket, errno 329)"
        ))
        #expect(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (errno=2)"
        ))
    }

    @Test func keepsRawSignalAndNonSocketMessages() {
        #expect(!filter.isExpectedCLISocketTransportMessage("SIGPIPE: Signal 13, Code 0"))
        #expect(!filter.isExpectedCLISocketTransportFailure(
            stage: "codex-monitor-start",
            message: "Failed to write to socket (Broken pipe, errno 32)"
        ))
    }
}
