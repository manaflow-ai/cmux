@testable import CmuxNextRemoteView
import Testing

/// Where an ended viewer session's report goes (goal screen-share-fast): the sink its builder
/// passed in, and only for a session that put a frame on glass.
@Suite struct RemoteRdSessionReportsTests {
    @Test func aSessionWithFramesReachesItsSinkAndOneWithoutIsDropped() async {
        let (sent, sink) = AsyncStream.makeStream(of: String.self)
        let reports = RemoteRdSessionReports { sink.yield($0) }
        let presented = #"{"schema":"cmux.rd-session-report/1","frames_presented":12,"presenting_s":0.4}"#
        reports.send(presented)
        reports.send(#"{"schema":"cmux.rd-session-report/1","frames_presented":0,"presenting_s":0.0}"#)
        sink.finish()
        var got: [String] = []
        for await report in sent { got.append(report) }
        #expect(got == [presented])
    }

    @Test func theDefaultDropsEveryReport() {
        RemoteRdSessionReports().send(#"{"frames_presented":3,"presenting_s":0.1}"#)
    }
}
