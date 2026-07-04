import XCTest
@testable import CmuxFoundation

final class SentryNoiseFilterTests: XCTestCase {
    private let filter = SentryNoiseFilter()

    func testDropsExpectedCLISocketDisconnectsInSocketStages() {
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "CLIError: Failed to write to socket (Broken pipe, errno 32) (Code: 1)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command_surface_list",
            message: "Failed to write to socket (Connection reset by peer, errno 54)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Bad file descriptor, errno 9)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "CLIError: Failed to write to socket (Bad file descriptor, errno 9) (Code: 1)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Socket not found at /tmp/cmux.sock"
        ))
    }

    func testKeepsActionableSocketFailures() {
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Operation timed out, errno 60)"
        ))
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Permission denied, errno 13)"
        ))
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write preferences file (Broken pipe, errno 32)"
        ))
    }

    func testErrnoMatchingRequiresExactCode() {
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (Invalid argument, errno 22)"
        ))
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_command",
            message: "Failed to write to socket (Not a socket, errno 329)"
        ))
        XCTAssertTrue(filter.isExpectedCLISocketTransportFailure(
            stage: "socket_connect",
            message: "Failed to connect to socket at /tmp/cmux.sock (errno=2)"
        ))
    }

    func testKeepsRawSignalAndNonSocketMessages() {
        XCTAssertFalse(filter.isExpectedCLISocketTransportMessage("SIGPIPE: Signal 13, Code 0"))
        XCTAssertFalse(filter.isExpectedCLISocketTransportFailure(
            stage: "codex-monitor-start",
            message: "Failed to write to socket (Broken pipe, errno 32)"
        ))
    }
}
