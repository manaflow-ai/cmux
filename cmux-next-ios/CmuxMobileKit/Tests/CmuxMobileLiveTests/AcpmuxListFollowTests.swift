import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's chat list follows the Mac's list cursor (acpmux `session-list-follow-v1`): a
/// reconnect with the whole list held, and a pull to refresh, read only the chats changed since
/// (design audit 2026-11-18, finding 8: each used to read every row, 30-38 MB from a Mac with
/// 10,000 chats).
@MainActor
@Suite struct AcpmuxListFollowTests {
    /// A Mac's acpmux as the row log answers it (`hub/row_log.rs`, `server/list_reply.rs`):
    /// every change takes the next list position; a watch with this run's `listEpoch` and an
    /// `afterSeq` it can follow gets the rows changed and gone since; any other watch gets the
    /// newest page with the position it is current to. Shared by the connections of one test.
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        var epoch = "run-1"
        var follows = true
        private var head: UInt64 = 0
        /// Each row's JSON and its last position, newest first by `updatedAt`.
        private var rows: [String: (json: [String: Any], at: UInt64, updated: Int)] = [:]
        private var gone: [(id: String, at: UInt64)] = []
        /// What every connection asked, in order, and the rows and bytes of each reply.
        private(set) var asked: [(method: String, rows: Int, bytes: Int)] = []

        init(chats: Int) {
            for n in 0..<chats { change("s\(n)", status: "idle") }
        }

        static func row(_ id: String, status: String, pending: Int = 0) -> [String: Any] {
            ["sessionId": id, "name": id, "harness": "fake", "cwd": "/tmp/w", "status": status,
             "title": String(repeating: "t", count: 64), "pendingPermissions": pending]
        }

        /// A chat changed (or was made): its next position.
        @discardableResult
        func change(_ id: String, status: String = "running", pending: Int = 0) -> UInt64 {
            lock.withLock {
                head += 1
                let updated = (rows[id]?.updated ?? 0) + Int(head)
                rows[id] = (Self.row(id, status: status, pending: pending), head, updated)
                return head
            }
        }

        func remove(_ id: String) {
            lock.withLock {
                head += 1
                rows[id] = nil
                gone.append((id, head))
            }
        }

        var position: UInt64 { lock.withLock { head } }
        func forget() { lock.withLock { asked = [] } }
        var methods: [String] { lock.withLock { asked.map(\.method) } }
        var rowsRead: Int { lock.withLock { asked.map(\.rows).reduce(0, +) } }

        /// The reply to `method` with `params`, as text.
        func answer(_ method: String, _ params: [String: Any]) -> String {
            lock.withLock {
                let result: [String: Any]
                switch method {
                case "initialize":
                    let capabilities = follows ? ["session-list-follow-v1"] : []
                    result = ["protocolVersion": 1, "_meta": ["acpmux": ["capabilities": capabilities]]]
                case "_acpmux/watch":
                    if follows, let after = (params["afterSeq"] as? NSNumber)?.uint64Value {
                        if params["listEpoch"] as? String == epoch, after <= head {
                            let changed = rows.filter { $0.value.at > after }.map(\.value.json)
                            let went = gone.filter { $0.at > after }.map { ["sessionId": $0.id] }
                            result = ["sessions": changed, "gone": went, "follow": true, "more": false,
                                      "listSeq": head, "listEpoch": epoch]
                        } else {
                            result = page(after: nil, limit: params["limit"] as? Int ?? 100, reset: true)
                        }
                    } else {
                        result = page(after: nil, limit: params["limit"] as? Int, reset: false)
                    }
                case "_acpmux/sessions":
                    result = page(after: params["cursor"] as? String, limit: params["limit"] as? Int, reset: false)
                default:
                    result = [:]
                }
                let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
                asked.append((method, (result["sessions"] as? [Any])?.count ?? 0, data.count))
                return String(decoding: data, as: UTF8.self)
            }
        }

        /// A page of the list, newest first, after the row named by `cursor`.
        private func page(after cursor: String?, limit: Int?, reset: Bool) -> [String: Any] {
            let ordered = rows.sorted { ($0.value.updated, $0.key) > ($1.value.updated, $1.key) }
            let start = cursor.flatMap { c in ordered.firstIndex { $0.key == c }.map { $0 + 1 } } ?? 0
            let end = limit.map { min(ordered.count, start + $0) } ?? ordered.count
            var result: [String: Any] = ["sessions": ordered[start..<end].map(\.value.json),
                                         "nextCursor": end < ordered.count ? ordered[end - 1].key as Any : NSNull()]
            if cursor == nil {
                result["listSeq"] = head
                result["listEpoch"] = epoch
                if reset { result["reset"] = true }
            }
            return result
        }
    }

    /// One connection to `mac`.
    final class Channel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        let mac: Mac
        private let inbox: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private var iterator: AsyncStream<Data>.AsyncIterator
        var closedBy: LinkError? { nil }

        init(_ mac: Mac) {
            self.mac = mac
            (inbox, continuation) = AsyncStream.makeStream()
            iterator = inbox.makeAsyncIterator()
        }

        func send(_ data: Data) async throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String, let id = object["id"] else { return }
            let result = mac.answer(method, object["params"] as? [String: Any] ?? [:])
            continuation.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
        }

        func notify(_ method: String, _ params: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])) ?? Data()
            continuation.yield(data)
        }

        func receive() async throws -> Data? { await iterator.next() }
        func close(code: String, reason: String) async { continuation.finish() }
    }

    static let wait: Duration = .seconds(30)

    /// A hub that read `mac`'s whole list on a first connection, as a phone does once.
    static func hubHoldingTheList(of mac: Mac) async -> (AcpmuxHub, Channel) {
        let hub = AcpmuxHub()
        let first = Channel(mac)
        await hub.bind(first)
        _ = await hub.waitUntilReady(timeout: wait, clock: ContinuousClock())
        await hub.restOfList?.value
        return (hub, first)
    }

    /// The detector: after the same changes, a reconnect and a refresh send the same requests
    /// and read the same rows from a Mac with 50 chats and one with 10,000. A phone read that
    /// grows with the Mac's list fails here.
    @Test func aReconnectAndARefreshReadOnlyTheChangesWhateverTheListsSize() async throws {
        var reads: [(connect: [String], connectRows: Int, refresh: [String], refreshRows: Int)] = []
        for chats in [50, 10_000] {
            let mac = Mac(chats: chats)
            let (hub, _) = await Self.hubHoldingTheList(of: mac)
            #expect(hub.listWhole)
            #expect(hub.sessions.count == chats)
            // Away: three chats change, one goes.
            for n in 0..<3 { mac.change("s\(n)") }
            mac.remove("s\(chats - 1)")
            mac.forget()
            await hub.bind(Channel(mac))
            #expect(await hub.waitUntilReady(timeout: Self.wait, clock: ContinuousClock()))
            let connect = (mac.methods, mac.rowsRead)
            #expect(hub.listWhole)
            #expect(hub.sessions.count == chats - 1)
            #expect(hub.sessions["s1"]?.status == "running")
            #expect(hub.sessions["s\(chats - 1)"] == nil)
            // Pull to refresh after three more.
            for n in 3..<6 { mac.change("s\(n)") }
            mac.forget()
            let feed = LiveFeed(store: FeedStore(items: []), hub: hub, place: { _ in nil })
            try await feed.refresh()
            #expect(hub.sessions["s4"]?.status == "running")
            reads.append((connect.0, connect.1, mac.methods, mac.rowsRead))
        }
        for read in reads {
            #expect(read.connect == ["initialize", "_acpmux/watch"], "a reconnect follows, no page is read")
            #expect(read.connectRows == 3)
            #expect(read.refresh == ["_acpmux/watch"], "a refresh follows, the list is not read again")
            #expect(read.refreshRows == 3)
        }
    }
}
