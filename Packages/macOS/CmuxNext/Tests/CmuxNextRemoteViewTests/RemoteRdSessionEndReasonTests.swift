import Foundation
@testable import CmuxNextRemoteView
import Testing

/// Why an rd session ended reaches its status (`endReason`, read by `cmux app remote-views`): the
/// carrier's close reason, nil while the session is live.
@Suite struct RemoteRdSessionEndReasonTests {
    private struct NoLink: Error, CustomStringConvertible {
        var description: String { "no link to the machine" }
    }

    @Test func aStreamThatDoesNotOpenEndsWithTheOpensError() async throws {
        let carrier = RemoteRdStreamCarrier(open: { throw NoLink() })
        let transport = try #require(RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(install: "test"),
                                                             startKey: "k"))
        var seen: [RemoteViewStatus] = []
        let statuses = transport.statusUpdates()
        transport.connect()
        // The transport finishes the stream once the session ends.
        for await status in statuses {
            seen.append(status)
        }
        let live = try #require(seen.first)
        #expect(live.state == .connecting)
        #expect(live.endReason == nil)
        let ended = try #require(seen.last)
        #expect(ended.state == .ended(.connectionLost), "the pane's state and behavior are unchanged")
        #expect(ended.endReason == "rd stream did not open: no link to the machine")
    }
}
