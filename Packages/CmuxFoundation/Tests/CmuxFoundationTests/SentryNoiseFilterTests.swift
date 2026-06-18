import XCTest
@testable import CmuxFoundation

final class SentryNoiseFilterTests: XCTestCase {
    func testDropsBrokenPipeSocketWrite() {
        // The exact production signature behind the ~10.9M-event flood.
        XCTAssertTrue(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to write to socket (Broken pipe, errno 32)"))
        XCTAssertTrue(SentryNoiseFilter.isExpectedPeerDisconnect(
            "CLIError: Failed to write to socket (Broken pipe, errno 32) (Code: 1)"))
    }

    func testDropsSigpipeAndResetAndBadDescriptorWrites() {
        XCTAssertTrue(SentryNoiseFilter.isExpectedPeerDisconnect("SIGPIPE: Signal 13, Code 0"))
        XCTAssertTrue(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to write to socket (Connection reset by peer, errno 54)"))
        XCTAssertTrue(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to write to socket (Bad file descriptor, errno 9)"))
    }

    func testKeepsActionableWriteFailures() {
        // Other write failures are real bugs and must still report.
        XCTAssertFalse(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to write to socket (Operation timed out, errno 60)"))
        XCTAssertFalse(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to write to socket (Permission denied, errno 13)"))
    }

    func testDoesNotMatchUnrelatedErrorsThatMentionTokens() {
        // "errno 32" outside a write context, or an unrelated message, stays.
        XCTAssertFalse(SentryNoiseFilter.isExpectedPeerDisconnect(
            "Failed to connect to socket at /tmp/x (No such file or directory, errno 2)"))
        XCTAssertFalse(SentryNoiseFilter.isExpectedPeerDisconnect("Event stream closed"))
        XCTAssertFalse(SentryNoiseFilter.isExpectedPeerDisconnect("Command timed out"))
    }
}
