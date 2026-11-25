import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite struct OrderedDaemonClientTests {
    private static let before = Data(#"{"event":"title-changed","surface":1,"title":"before"}"#.utf8)
    private static let after = Data(#"{"event":"title-changed","surface":1,"title":"after"}"#.utf8)

    @Test(.timeLimit(.minutes(1)))
    func snapshotReplyAndEventsShareWireOrderWithinOneRead() async throws {
        let link = MockMacLink { _, bytes in
            guard let request = try? JSONSerialization.jsonObject(with: bytes.dropLast()) as? [String: Any],
                  let id = request["id"] as? String else { return [] }
            // Preserve spacing and escaped content: requestOrdered must return
            // the bytes from the wire, not a re-encoded JSON representation.
            let reply = Self.reply(id: id)
            return [Self.before + Data([0x0A]) + reply + Data([0x0A]) + Self.after + Data([0x0A])]
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]), orderedEvents: true)
        let reply = try await client.requestOrdered("list-workspaces")
        await client.close()
        var events = client.orderedEvents.makeAsyncIterator()
        let before = try #require(await events.next())
        let after = try #require(await events.next())
        #expect(before.data == Self.before)
        #expect(reply.data == Self.reply(id: "m1"))
        #expect(after.data == Self.after)
        #expect(before.sequence == 1)
        #expect(reply.sequence == 2)
        #expect(after.sequence == 3)
        #expect(await events.next()?.data == nil)
        var unused = client.events.makeAsyncIterator()
        #expect(await unused.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func batchReplyPositionsIncludeEventsAndKeepRequestOrder() async throws {
        let writes = Counter()
        let link = MockMacLink { _, bytes in
            writes.add()
            let ids = bytes.split(separator: 0x0A).compactMap { line -> String? in
                (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])?["id"] as? String
            }
            guard ids.count == 2 else { return [] }
            // Deliberately reverse the replies in a single read. Results still
            // follow request order, while sequences expose actual wire order.
            return [Self.before + Data([0x0A]) + Self.reply(id: ids[1]) + Data([0x0A])
                + Self.after + Data([0x0A]) + Self.reply(id: ids[0]) + Data([0x0A])]
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]), orderedEvents: true)
        let results = await client.requestsOrdered([("identify", [:]), ("list-workspaces", [:])])
        await client.close()
        #expect(writes.value == 1)
        #expect(results.count == 2)
        let replies = try results.map { try $0.get() }
        #expect(replies.map(\.data) == [Self.reply(id: "m1"), Self.reply(id: "m2")])
        #expect(replies.map(\.sequence) == [4, 2])
        var events = client.orderedEvents.makeAsyncIterator()
        let before = try #require(await events.next())
        let after = try #require(await events.next())
        #expect(before.sequence == 1)
        #expect(after.sequence == 3)
        #expect(before.data == Self.before)
        #expect(after.data == Self.after)
        #expect(await events.next()?.data == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultStreamStillReturnsOriginalEventAndReplyBytes() async throws {
        let link = MockMacLink { _, bytes in
            guard let request = try? JSONSerialization.jsonObject(with: bytes.dropLast()) as? [String: Any],
                  let id = request["id"] as? String else { return [] }
            return [Self.before + Data([0x0A]) + Self.reply(id: id) + Data([0x0A]) + Self.after + Data([0x0A])]
        }
        let client = DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        let reply = try await client.request("list-workspaces")
        await client.close()
        #expect(reply == Self.reply(id: "m1"))
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == Self.before)
        #expect(await events.next() == Self.after)
        #expect(await events.next() == nil)
        var unused = client.orderedEvents.makeAsyncIterator()
        #expect(await unused.next()?.data == nil)
    }

    private static func reply(id: String) -> Data {
        Data(#"{ "id": "\#(id)", "ok": true, "data": {"title":"one\ntwo", "workspaces": []} }"#.utf8)
    }
}
