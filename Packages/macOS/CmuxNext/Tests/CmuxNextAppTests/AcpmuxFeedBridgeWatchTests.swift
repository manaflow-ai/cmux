@testable import CmuxNextApp
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The feed bridge watches every session only to hear `_acpmux/permission_pending` and
/// `_acpmux/session_changed`; it never needed the list. Asked without a limit, its watch answered
/// the daemon's whole session list, 31 MB on a Mac that mirrors ~10,000 peer sessions, past its
/// line reader's cap: the connection closed, reconnected after its backoff and asked for the same
/// 31 MB again, about nine times a minute, with nothing gained.
struct AcpmuxFeedBridgeWatchTests {
    static func request(_ line: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    @Test func theWatchAsksForOneRowNotTheWholeList() throws {
        let watch = try Self.request(Data.acpmuxFeedWatch)
        #expect(watch["method"] as? String == "_acpmux/watch")
        let params = try #require(watch["params"] as? [String: Any])
        #expect(params["enabled"] as? Bool == true)
        #expect(params["limit"] as? Int == 1)
    }

    @Test func theSessionsWithPendingPromptsAreReadByTheirOwnFilter() throws {
        let pending = try Self.request(Data.acpmuxPendingSessions)
        #expect(pending["method"] as? String == "_acpmux/sessions")
        let params = try #require(pending["params"] as? [String: Any])
        #expect(params["pendingOnly"] as? Bool == true)
        #expect(params["limit"] == nil)
    }

    /// acpmux sends one message of up to `rpc::MAX_MESSAGE_BYTES` (31 MiB) as one line: a reader
    /// whose cap is below it closes on a reply the daemon may send, and asking again gets the same.
    @Test func aCheckedLineAcceptsTheLargestMessageAcpmuxSends() {
        #expect(AcpmuxCheckedLine.maxLine > 31 << 20)
    }
}
