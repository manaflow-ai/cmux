import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// What a screen share viewer session sends at its end (goal screen-share-fast): the Rust core's
/// session report as one info event, numbers only.
@Suite struct ScreenShareSessionEventTests {
    @Test func aSessionReportBecomesOneInfoEventWithItsNumbers() throws {
        let json = #"{"schema":"cmux.rd-session-report/1","first_frame_ms":640.0,"total":{"n":9000,"p50_ms":20.0,"p95_ms":31.5},"present":{"n":9100,"p50_ms":4.0,"p95_ms":6.5},"frames_presented":9100,"presenting_s":151.7}"#
        let session = try #require(ScreenShareSessionEvent(reportJSON: json))
        #expect(session.firstFrameMs == 640)
        #expect(session.totalP95Ms == 31.5)
        #expect(session.totalCount == 9000)
        let event = session.event()
        #expect(event.level == .info)
        #expect(event.fingerprint == ["screen_share_session"])
        #expect(event.tags?["screen_share"] == "session")
        #expect(event.tags?["total_p95_ms"] == "31.5")
        #expect(event.extra?["first_frame_ms"] as? Double == 640)
        #expect(event.extra?["frames_presented"] as? Int == 9100)
    }

    @Test func aSessionWithNoClockLeavesItsTotalOut() throws {
        let json = #"{"schema":"cmux.rd-session-report/1","first_frame_ms":18.0,"total":null,"present":{"n":1,"p50_ms":8.0,"p95_ms":8.0},"frames_presented":1,"presenting_s":0.0}"#
        let event = try #require(ScreenShareSessionEvent(reportJSON: json)).event()
        #expect(event.extra?["total_p95_ms"] == nil)
        #expect(event.tags?["present_p95_ms"] == "8.0")
    }

    @Test func otherTextIsNotASessionReport() {
        #expect(ScreenShareSessionEvent(reportJSON: #"{"schema":"cmux.rd-stage-ledger/1"}"#) == nil)
        #expect(ScreenShareSessionEvent(reportJSON: "not json") == nil)
    }
}
