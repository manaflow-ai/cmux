#if DEBUG
@testable import CMUXDebugLog
import XCTest

final class DebugLogRedactorTests: XCTestCase {
    func testPreservesOrdinaryFields() {
        let message = "browser.nav stage=start status=200 mime=text/html bytes=123"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    func testRedactsURLFieldsToOrigin() {
        let message = "browser.nav url=https://example.com/account?token=secret status=200"

        XCTAssertEqual(
            DebugEventLog.redactedDebugMessage(message),
            "browser.nav url=https://example.com status=200"
        )
    }

    func testRedactsPathLikeFieldsWithSpaces() {
        let message = "download.saved path=/Users/person/Tax Docs/report.pdf bytes=42"

        XCTAssertEqual(
            DebugEventLog.redactedDebugMessage(message),
            "download.saved path=<redacted:33b> bytes=42"
        )
    }

    func testPayloadConsumesRemainder() {
        let message = "browser.context payload={\"title\":\"Bank Account\"} action=open"

        XCTAssertEqual(
            DebugEventLog.redactedDebugMessage(message),
            "browser.context payload=<redacted:36b>"
        )
    }

    func testNilValuesRemainReadable() {
        let message = "browser.nav url=nil path=(nil) token=nil"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    // The typing/turn probes use `path=` for an instrumentation identifier, not a
    // filesystem path. Both the identifier and the numeric measurement must survive
    // so per-path latency can be bucketed from the tagged debug log.
    func testTypingTimingProbeSurvivesUnredacted() {
        let message = "typing.timing path=terminal.keyDown elapsedMs=2.34 eventType=10 keyCode=0 mods=256 repeat=0"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    func testTypingPhaseProbeSurvivesUnredacted() {
        let message = "typing.phase path=terminal.keyDown totalMs=3.10 ghosttySend.total=2.05 interpretKeyEvents=0.80"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    func testHandleActionProbeSurvivesUnredacted() {
        let message = "typing.timing path=terminal.handleAction.RENDER elapsedMs=0.42"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    func testTurnWorkProbeNumbersSurvive() {
        let message = "main.turn.work turnMs=8.10 trackedMs=4.20 totalCount=3 next=beforeWaiting"

        XCTAssertEqual(DebugEventLog.redactedDebugMessage(message), message)
    }

    // Real filesystem `path=` outside the probe lines must still be redacted.
    func testNonProbePathStillRedacted() {
        let message = "download.saved path=/Users/person/report.pdf bytes=42"

        XCTAssertEqual(
            DebugEventLog.redactedDebugMessage(message),
            "download.saved path=<redacted:24b> bytes=42"
        )
    }
}
#endif
