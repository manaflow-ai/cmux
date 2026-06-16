import XCTest
@testable import CmuxFoundation

final class SentryNoiseFilterTests: XCTestCase {
    func testDropsExpectedCLISocketDisconnectsInSocketStages() {
        XCTAssertTrue(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "CLIError: Failed to write to socket (Broken pipe, errno 32) (Code: 1)"
        ))
        XCTAssertTrue(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_command_surface_list",
            message: "Failed to write to socket (Connection reset by peer, errno 54)"
        ))
        XCTAssertTrue(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)"
        ))
        XCTAssertTrue(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Socket not found at /tmp/cmux.sock"
        ))
    }

    func testKeepsActionableSocketFailures() {
        XCTAssertFalse(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Operation timed out, errno 60)"
        ))
        XCTAssertFalse(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Permission denied, errno 13)"
        ))
    }

    func testKeepsRawSignalAndNonSocketMessages() {
        XCTAssertFalse(SentryNoiseFilter.isExpectedCLISocketTransportMessage("SIGPIPE: Signal 13, Code 0"))
        XCTAssertFalse(SentryNoiseFilter.isExpectedCLISocketTransportFailure(
            stage: "codex-monitor-start",
            message: "Failed to write to socket (Broken pipe, errno 32)"
        ))
    }
}
