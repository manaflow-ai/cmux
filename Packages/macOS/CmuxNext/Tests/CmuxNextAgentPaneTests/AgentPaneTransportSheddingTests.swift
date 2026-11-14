import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A page that falls a full queue behind loses stream notifications, never its connection
/// (AcpmuxPaneShedding.swift). Before, the transport closed the socket (`transport.inbound_overflow`),
/// the page connected again and read its chat and the list anew, which filled the queue again:
/// Leo's chat reconnected every 4 to 9 seconds for minutes (2026-11-11, up to 156 closes in 10
/// minutes), flipping between a kept tail and the live chat.
struct AgentPaneTransportSheddingTests {
    private static func socket(_ limits: AgentPaneTransport.Limits) throws -> AcpmuxPaneSocket {
        let url = try #require(URL(string: "ws://127.0.0.1"))
        return AcpmuxPaneSocket(request: URLRequest(url: url), limits: limits, options: AcpmuxPermissionOptions(),
                                sessions: AcpmuxPaneSessions(), ids: AcpmuxRequestIds(), signal: {})
    }

    private static func small() -> AgentPaneTransport.Limits {
        var limits = AgentPaneTransport.Limits()
        limits.maximumQueuedFrames = 8
        limits.maximumQueuedBytes = 1 << 20
        return limits
    }

    private static func chunk(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"record":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}}"#
    }

    /// A streamed chunk of about 16 KB.
    private static func bigChunk(_ seq: Int) -> String {
        let text = String(repeating: "y", count: 16 << 10)
        return #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"record":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}}"#
    }

    /// Everything the page would get now, as one drain of the pacer.
    private static func drain(_ socket: AcpmuxPaneSocket) -> AcpmuxPaneSocket.Batch {
        socket.waitForInboundPasses()
        var all = AcpmuxPaneSocket.Batch(frames: [], closed: nil, more: false)
        while true {
            let batch = socket.take(maximumFrames: 512, maximumBytes: 64 << 20)
            all.frames += batch.frames
            all.closed = all.closed ?? batch.closed
            if !batch.more { break }
        }
        // A shed episode ends on the inbound queue once the page caught up.
        socket.waitForInboundPasses()
        let tail = socket.take(maximumFrames: 512, maximumBytes: 64 << 20)
        all.frames += tail.frames
        all.closed = all.closed ?? tail.closed
        return all
    }

    private static func lagMarkers(_ frames: [String]) -> [String] {
        frames.filter { $0.contains(#""method":"_acpmux/lagged""#) }
    }

    /// The `dropped` counts the markers name, summed.
    private static func dropped(_ frames: [String]) -> Int {
        lagMarkers(frames).reduce(0) { total, marker in
            guard let object = try? JSONSerialization.jsonObject(with: Data(marker.utf8)) as? [String: Any],
                  let params = object["params"] as? [String: Any], let count = params["dropped"] as? Int else { return total }
            return total + count
        }
    }

    @Test func aFullQueueShedsNotificationsAndKeepsTheConnection() throws {
        let socket = try Self.socket(Self.small())
        for seq in 1...40 { socket.receiveLocalReply(Self.chunk(seq)) }
        let batch = Self.drain(socket)
        #expect(!socket.isClosed)
        #expect(batch.closed == nil)
        // The page got what fit, then one marker that names how many it missed: every frame sent
        // is either delivered or counted. (The bound is soft: frames an inbound pass is checking are
        // in neither queue, so how many fit depends on timing.)
        let markers = Self.lagMarkers(batch.frames)
        #expect(!markers.isEmpty)
        let kept = batch.frames.count - markers.count
        #expect(kept >= 1 && kept < 40)
        #expect(kept + Self.dropped(batch.frames) == 40)
        #expect(markers.first?.contains(#""watch":true"#) == true)
        // Caught up: notifications flow again, with no further marker.
        socket.receiveLocalReply(Self.chunk(41))
        let after = Self.drain(socket)
        #expect(after.frames == [Self.chunk(41)])
    }

    @Test func repliesRequestsAndObservedNotificationsAreNeverShed() throws {
        let socket = try Self.socket(Self.small())
        for seq in 1...20 { socket.receiveLocalReply(Self.chunk(seq)) }
        // A request to the page waits on its answer; an observed notification feeds a host observer.
        let request = #"{"jsonrpc":"2.0","id":"q1","method":"session/request_permission","params":{"sessionId":"s"}}"#
        let accepted = #"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"promptId":"p1"}}"#
        let permission = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":99,"record":{"sessionUpdate":"permission_request"}}}"#
        socket.receiveLocalReply(request)
        socket.receiveLocalReply(accepted)
        socket.receiveLocalReply(permission)
        let batch = Self.drain(socket)
        #expect(!socket.isClosed)
        #expect(batch.frames.contains(accepted))
        #expect(batch.frames.contains(permission))
        // The request reached the page (its id is the daemon's: no relay entry rewrites it).
        #expect(batch.frames.contains { $0.contains("session/request_permission") })
        #expect(!Self.lagMarkers(batch.frames).isEmpty)
    }

    /// Leo's loop: one ~31 MB list reply (the daemon's largest frame) took 31 of the queue's 32 MB,
    /// so the next streamed chunk closed the connection, and the reconnect asked for the list again.
    @Test func aWholeLargestFrameReplyWithAStreamAroundItKeepsTheConnection() throws {
        let socket = try Self.socket(AgentPaneTransport.Limits())
        let filler = String(repeating: "a", count: (31 << 20) - 64)
        // A frame the page gets whole (one with an id; a reply with no relay entry here would be
        // dropped once checked, and free its bytes before the stream fills the queue).
        let reply = #"{"jsonrpc":"2.0","id":1,"method":"x/list","params":{"pad":"\#(filler)"}}"#
        socket.receiveLocalReply(Self.chunk(1))
        socket.receiveLocalReply(reply)
        // About 3 MB streamed while the page reads the reply: past the 32 MB the queue holds.
        for seq in 2...200 { socket.receiveLocalReply(Self.bigChunk(seq)) }
        let batch = Self.drain(socket)
        #expect(!socket.isClosed)
        #expect(batch.closed == nil)
        // The reply arrived whole, and every chunk was delivered or counted in at most one marker.
        #expect(batch.frames.contains(reply))
        let markers = Self.lagMarkers(batch.frames)
        #expect(batch.frames.count - markers.count + Self.dropped(batch.frames) == 201)
    }

    /// The reconnect loop's shape, many times over: the page falls behind, catches up, and falls
    /// behind again. The connection never closes, and each episode ends in exactly one marker.
    @Test func manyBacklogEpisodesNeverCloseTheConnection() throws {
        let socket = try Self.socket(Self.small())
        var seq = 0
        for _ in 0..<50 {
            for _ in 0..<30 {
                seq += 1
                socket.receiveLocalReply(Self.chunk(seq))
            }
            let batch = Self.drain(socket)
            #expect(batch.closed == nil)
            let markers = Self.lagMarkers(batch.frames)
            #expect(!markers.isEmpty)
            #expect(batch.frames.count - markers.count + Self.dropped(batch.frames) == 30)
        }
        #expect(!socket.isClosed)
    }

    @Test func onlyRepliesPastTheCeilingCloseTheConnection() throws {
        var limits = Self.small()
        limits.ceilingQueuedFrames = 12
        let socket = try Self.socket(limits)
        // Requests to the page: never shed, and nobody takes them here.
        // Each settled before the next, so every one counts (a frame an inbound pass is checking
        // is in neither queue).
        for id in 1...11 {
            socket.receiveLocalReply(#"{"jsonrpc":"2.0","id":\#(id),"method":"x/y","params":{}}"#)
            socket.waitForInboundPasses()
        }
        #expect(!socket.isClosed)
        socket.receiveLocalReply(#"{"jsonrpc":"2.0","id":12,"method":"x/y","params":{}}"#)
        socket.waitForInboundPasses()
        socket.receiveLocalReply(#"{"jsonrpc":"2.0","id":13,"method":"x/y","params":{}}"#)
        socket.waitForInboundPasses()
        #expect(socket.isClosed)
    }

    @Test func notificationMethodReadsOnlyTopLevelKeys() {
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"jsonrpc":"2.0","method":"a/b","params":{"id":1}}"#) == "a/b")
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"params":{"method":"x"},"method":"a/b"}"#) == "a/b")
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"jsonrpc":"2.0","id":3,"method":"a/b"}"#) == nil)
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"method":"a/b","id":"z"}"#) == nil)
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"jsonrpc":"2.0","id":3,"result":{"method":"a"}}"#) == nil)
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"method":"a/b"}"#) == "a/b")
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"method":"a\/b"}"#) == nil)
        #expect(AcpmuxPaneShedding.notificationMethod("not json") == nil)
        #expect(AcpmuxPaneShedding.notificationMethod(#"{"method":"a/b","params":{"text":"\"}\"{"}}"#) == "a/b")
    }
}
