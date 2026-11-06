import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The `_acpmux/watch` requests a Mac's acpmux was sent, with their params.
final class WatchAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[String: Any]] = []
    func add(_ params: [String: Any]) { lock.withLock { asked.append(params) } }
    var all: [[String: Any]] { lock.withLock { asked } }
}

/// A busy acpmux follows a list reply that went out after a `session_changed` with
/// `_acpmux/lagged {watch: true, dropped: 0, reason: "list_changed"}`. The phone asked for the
/// whole watch again on every lag, and that reply came with the same lag: a 25 MB list about
/// every minute without end on a Mac with about 500 chats (2026-11-06).
@MainActor
@Suite struct AcpmuxLagTests {
    /// A Mac whose every watch reply is followed by `lag` (nil: none after the first).
    static func mac(_ asks: WatchAsks, lag: @escaping @Sendable (Int) -> String?) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                asks.add(object["params"] as? [String: Any] ?? [:])
                let list = reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"idle","lastSeq":1}]}"#)
                guard let lag = lag(asks.all.count) else { return [list] }
                return [list, Data(#"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":\#(lag)}"#.utf8)]
            default: return [reply("{}")]
            }
        }
    }

    /// Lets the hub handle what came and run the work it started: a few round trips.
    static func settle(_ hub: AcpmuxHub) async {
        for _ in 0..<8 {
            _ = try? await hub.request("_acpmux/status", .object([:]), timeout: .seconds(5))
            await Task.yield()
        }
    }

    @Test func aListChangedLagReadsNothingAgain() async throws {
        let asks = WatchAsks()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(asks) { _ in #"{"watch":true,"dropped":0,"reason":"list_changed"}"# }
            .openChannel(service: "acpmux", args: [:]))
        await Self.settle(hub)
        #expect(hub.isReady)
        #expect(asks.all.count == 1)
    }

    @Test func aLagThatDroppedNoticesTurnsTheWatchOnWithOneRow() async throws {
        let asks = WatchAsks()
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac(asks) { asked in asked == 1 ? #"{"watch":true,"dropped":3}"# : nil }
            .openChannel(service: "acpmux", args: [:]))
        await Self.settle(hub)
        #expect(asks.all.count == 2)
        #expect(asks.all.last?["limit"] as? Int == 1)
        #expect(asks.all.last?["enabled"] as? Bool == true)
    }
}
