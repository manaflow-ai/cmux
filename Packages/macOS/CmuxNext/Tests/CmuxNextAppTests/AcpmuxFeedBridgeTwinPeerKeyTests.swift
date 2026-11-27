@testable import CmuxNextApp
@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Two peers' sessions can share a raw `sessionId` (review of manaflow-ai/cmux#41240, F1). The
/// feed bridge keys each one's phone item on its own qualified id (`peer/id`): a prompt of each
/// is posted under its own thread, and when one peer resolves its prompt, only that item is
/// withdrawn, read by that peer's qualified id. Keyed on the raw id, the first resolution read
/// the ambiguous raw id and withdrew both items, the other peer's prompt still pending.
@MainActor @Suite(.serialized) struct AcpmuxFeedBridgeTwinPeerKeyTests {
    typealias Fake = AcpmuxFeedBridgeLateAnswerTests.LateAcpmux
    static let raw = "acp_peer_late"

    /// `daemonSendsQualifiedId` false: what acpmux sent before the field (raw id and peer only).
    @Test(arguments: [true, false])
    func eachPeersPromptIsAddedAndWithdrawnOnItsOwn(daemonSendsQualifiedId: Bool) async throws {
        let socket = "/tmp/aftp-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let daemon = try Fake(socket: socket)
        defer { daemon.stop() }
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
            pendingReads: AcpmuxPendingReads(width: 4, deadline: .seconds(10), clock: ManualClock()))
        defer { bridge = nil }
        bridge?.start()

        // Recovery finds nothing pending.
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 1, within: .seconds(10))
        daemon.answerInfo(pending: [])

        func ids(_ peer: String) -> [String: Any] {
            var ids: [String: Any] = ["sessionId": Self.raw, "peer": peer]
            if daemonSendsQualifiedId { ids["qualifiedSessionId"] = "\(peer)/\(Self.raw)" }
            return ids
        }
        // A live prompt of each peer's session, both with the same raw id.
        for (peer, permission) in [("peer-a", "perm-a"), ("peer-b", "perm-b")] {
            daemon.notify("_acpmux/permission_pending", ids(peer).merging([
                "permissionId": permission, "request": Fake.request, "seq": 10, "via": "peer",
            ]) { $1 })
        }
        await posts.count(2, within: .seconds(5))
        let added = posts.all
        #expect(added.allSatisfy { $0.op == "feed.post" }, "posts: \(added)")
        func item(_ permission: String) -> String? {
            added.firstIndex { $0.permission == "acpmux:\(permission)" }.map { "item-\($0 + 1)" }
        }
        let (itemA, itemB) = (try #require(item("perm-a")), try #require(item("perm-b")))
        let threads = Dictionary(uniqueKeysWithValues: added.compactMap { post in post.permission.map { ($0, post.thread) } })
        #expect(threads["acpmux:perm-a"] == "acpmux:peer-a/\(Self.raw)", "\(threads)")
        #expect(threads["acpmux:perm-b"] == "acpmux:peer-b/\(Self.raw)", "\(threads)")

        // Peer a resolves its prompt: the bridge reads peer a's session and withdraws its item only.
        func resolve(_ peer: String, seq: Int) {
            daemon.notify("_acpmux/session_changed", ids(peer).merging([
                "kind": "permission_resolved", "recordKind": "permission_auto", "seq": seq, "session": ids(peer),
            ]) { $1 })
        }
        resolve("peer-a", seq: 11)
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 2, within: .seconds(10))
        #expect(daemon.infoAsked.last == "peer-a/\(Self.raw)", "info reads: \(daemon.infoAsked)")
        daemon.answerInfo(pending: [])
        await posts.count(3, within: .seconds(5))
        #expect(posts.all.last?.op == "feed.cancel" && posts.all.last?.permission == "cancel:\(itemA)", "posts: \(posts.all)")

        // Peer b's item is still posted: its own resolution reads peer b's session and withdraws it.
        resolve("peer-b", seq: 12)
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 3, within: .seconds(10))
        #expect(daemon.infoAsked.last == "peer-b/\(Self.raw)", "info reads: \(daemon.infoAsked)")
        daemon.answerInfo(pending: [])
        await posts.count(4, within: .seconds(5))
        bridge = nil
        #expect(posts.all.count == 4, "posts: \(posts.all)")
        #expect(posts.all.last?.op == "feed.cancel" && posts.all.last?.permission == "cancel:\(itemB)", "posts: \(posts.all)")
    }
}
