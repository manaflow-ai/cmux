@testable import CmuxNextApp
@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A peer session's live notices name it by its raw `sessionId`, with `peer` and (from acpmux
/// with the field) `qualifiedSessionId`; the bridge's recovery names the same session by its
/// row's qualified id (``AcpmuxPendingReads/sessionKey(_:)``). The live notices must use that key
/// too: a `session_changed` for a prompt the recovery posted withdraws it, and a live
/// `permission_pending` posts under the recovery's thread.
@MainActor @Suite(.serialized) struct AcpmuxFeedBridgePeerNoticeKeyTests {
    typealias Fake = AcpmuxFeedBridgeLateAnswerTests.LateAcpmux
    static let qualified = "peer-a/acp_peer_late"

    /// `daemonSendsQualifiedId` false: what acpmux sent before the field (raw id and peer only).
    @Test(arguments: [true, false], ["permission_resolved", "permission_decision"])
    func aPeerSessionsLiveNoticesUseTheRecoverysKey(daemonSendsQualifiedId: Bool, kind: String) async throws {
        let socket = "/tmp/afpk-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let daemon = try Fake(socket: socket)
        defer { daemon.stop() }
        let clock = ManualClock()
        let posts = AcpmuxFeedBridgeLateAnswerTests.Posts()
        var bridge: AcpmuxPermissionFeedBridge? = AcpmuxPermissionFeedBridge(
            environment: try AcpmuxFeedBridgeLateAnswerTests.environment(socket),
            owner: { _, body in
                let params = body["params"] as? [String: Any]
                posts.add(op: body["op"] as? String, permission: body["idempotency_key"] as? String,
                          afterAnswer: daemon.answered, thread: params?["thread"] as? String)
                return ["value": ["item": ["id": "item-\(posts.all.count)"]]]
            },
            isSignedIn: { true }, ownInstall: { "inst_mac" },
            presenceKeys: { throw CancellationError() },
            pendingReads: AcpmuxPendingReads(width: 4, deadline: .seconds(10), clock: clock))
        defer { bridge = nil }
        bridge?.start()

        // Recovery reads the peer row's prompt by the row's qualified id and posts it.
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 1, within: .seconds(10))
        daemon.answerInfo()
        await posts.count(1, within: .seconds(5))
        let recovered = try #require(posts.all.first)
        #expect(recovered.op == "feed.post")
        #expect(recovered.thread == "acpmux:\(Self.qualified)", "\(recovered)")

        // The peer's notices: the raw id, the peer and (newer acpmux) the row's qualified id.
        var peerIds: [String: Any] = ["sessionId": "acp_peer_late", "peer": "peer-a"]
        if daemonSendsQualifiedId { peerIds["qualifiedSessionId"] = Self.qualified }

        // Answered elsewhere: the bridge re-reads that session and withdraws the posted item.
        daemon.notify("_acpmux/session_changed", peerIds.merging([
            "kind": kind, "recordKind": kind == "permission_resolved" ? "permission_auto" : kind, "seq": 9,
            "session": peerIds,
        ]) { $1 })
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 2, within: .seconds(10))
        #expect(daemon.infoAsked.last == Self.qualified, "info reads: \(daemon.infoAsked)")
        daemon.answerInfo(pending: [])
        await posts.count(2, within: .seconds(5))
        #expect(posts.all.count == 2 && posts.all.last?.op == "feed.cancel", "posts: \(posts.all)")

        // A new live prompt of that session posts under the recovery's thread.
        daemon.notify("_acpmux/permission_pending", peerIds.merging([
            "permissionId": "perm-live", "request": Fake.request, "seq": 10, "via": "peer",
        ]) { $1 })
        await posts.count(3, within: .seconds(5))
        bridge = nil
        #expect(posts.all.count == 3, "posts: \(posts.all)")
        #expect(posts.all.last?.op == "feed.post")
        #expect(posts.all.last?.permission == "acpmux:perm-live")
        #expect(posts.all.last?.thread == recovered.thread, "posts: \(posts.all)")
    }
}
