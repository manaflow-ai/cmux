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
}
#endif
