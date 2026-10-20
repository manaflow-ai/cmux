import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite struct DaemonClientTests {
    @Test func repliesRouteByIDAndEventsStream() async throws {
        let link = MockMacLink { _, request in
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let event = Data(#"{"event":"tree.changed"}"#.utf8) + Data([0x0A])
            // Reply split across two chunks to exercise line buffering.
            let reply = Data(#"{"id":"\#(id)","ok":true,"data":{"cmd":"\#(object["cmd"]!)"}}"#.utf8) + Data([0x0A])
            return [event, reply.prefix(10), reply.dropFirst(10)]
        }
        let channel = try await link.openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let reply = try await client.request("identify")
        let object = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
        #expect(object["ok"] as? Bool == true)
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event.map { String(decoding: $0, as: UTF8.self) } == #"{"event":"tree.changed"}"#)
    }

    /// The connect setup goes out as one write and the replies come back in order.
    @Test func batchSendsOneWriteAndKeepsOrder() async throws {
        let writes = Counter()
        let link = MockMacLink { _, request in
            writes.add()
            var replies = Data()
            for line in request.split(separator: 0x0A) {
                let object = try! JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                let id = object["id"] as! String
                let ok = object["cmd"] as! String != "refused"
                replies += Data(#"{"id":"\#(id)","ok":\#(ok),"data":{"cmd":"\#(object["cmd"]!)"}}"#.utf8) + Data([0x0A])
            }
            // Replies in one chunk, as a fast Mac sends them.
            return [replies]
        }
        let channel = try await link.openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let results = await client.requests([("identify", [:]), ("refused", [:]), ("list-workspaces", [:])])
        #expect(writes.value == 1)
        let commands = results.map { result -> String? in
            guard let data = try? result.get(),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (object["data"] as? [String: Any])?["cmd"] as? String
        }
        #expect(commands == ["identify", "refused", "list-workspaces"])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
