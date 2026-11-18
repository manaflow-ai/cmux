
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Audit 17 (fallbacks that hide a failure): a chat waiting on an ask whose records could not be
/// read showed "Needs you" with no card, and the failure was dropped. Now the failure is logged
/// with its reason, the Feed's Needs you row says it plainly while it is read again, and the
/// card takes its place once the read succeeds.
@MainActor
@Suite struct FeedSeedRetryTests {
    nonisolated static let waiting = #"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"waiting","pendingPermissions":1,"lastSeq":3}]}"#
    nonisolated static let events = #"{"events":[{"sessionId":"s1","seq":3,"kind":"permission_request","msg":{"permissionId":"perm","request":{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#

    /// How many `_acpmux/events` reads fail before one succeeds.
    final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        private(set) var reads = 0
        init(_ count: Int) { left = count }
        func next() -> Bool {
            lock.withLock {
                reads += 1
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
    }

    static func mac(failing failures: Failures) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(waiting)]
            case "_acpmux/events":
                if failures.next() {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"event log busy"}}"#.utf8)]
                }
                return [reply(events)]
            default: return [reply("{}")]
            }
        }
    }

    static func settle(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the retry, to a deadline
        }
    }

    /// The same with the app's own retry delays and telemetry, through nothing but the hub's and
    /// the Feed's public wiring: this one compiles on the old code, where it fails (no card).
    @Test func aSeedThatThrowsOnceStillEndsWithTheCard() async throws {
        let failures = Failures(1)
        let hub = AcpmuxHub()
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed
        hub.onWatchEvent = { [weak hub] event in
            guard let hub else { return }
            feed.handle(event, sessions: hub.sessions)
        }
        await hub.bind(try await Self.mac(failing: failures).openChannel(service: "acpmux", args: [:]))
        await Self.settle { store.item(id: "ask-perm") != nil }
        #expect(store.item(id: "ask-perm")?.needsYou == true)
        #expect(failures.reads == 2)
    }

}
