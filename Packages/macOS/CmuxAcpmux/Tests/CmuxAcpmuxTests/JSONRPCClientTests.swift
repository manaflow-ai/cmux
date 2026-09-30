import Foundation
import Testing
@testable import CmuxAcpmux

struct JSONRPCClientTests {
    @Test func correlatesOutOfOrderResponsesAndStreamsNotifications() async throws {
        let (inbound, feed) = AsyncStream<Data>.makeStream()
        let (written, writtenFeed) = AsyncStream<Data>.makeStream()
        let client = JSONRPCClient(
            inbound: inbound,
            write: { writtenFeed.yield($0) },
            close: { feed.finish() }
        )
        let first = Task { try await client.request("a", params: ["x": 1]) }
        let second = Task { try await client.request("b", params: ["y": 2]) }
        var writes = written.makeAsyncIterator()
        _ = await writes.next()
        _ = await writes.next()
        // Responses arrive out of order, split across chunks, with a notification between.
        feed.yield(Data((#"{"jsonrpc":"2.0","id":2,"result":"two"}"# + "\n" + #"{"jsonrpc":"2.0","method":"n","params":{"k":true}}"#).utf8))
        feed.yield(Data("\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"one\"}\n".utf8))
        let results = try await [first.value, second.value]
        #expect(Set(results) == [.string("one"), .string("two")])
        var iterator = client.notifications.makeAsyncIterator()
        let note = await iterator.next()
        #expect(note == JSONRPCNotification(method: "n", params: .object(["k": .bool(true)])))
    }

    @Test func disconnectFailsPendingRequests() async throws {
        let (inbound, feed) = AsyncStream<Data>.makeStream()
        let (written, writtenFeed) = AsyncStream<Data>.makeStream()
        let client = JSONRPCClient(inbound: inbound, write: { writtenFeed.yield($0) }, close: {})
        let pending = Task { try await client.request("slow", params: [String: String]()) }
        var writes = written.makeAsyncIterator()
        _ = await writes.next()
        feed.finish()
        await #expect(throws: JSONRPCClientError.disconnected) { _ = try await pending.value }
    }
}
