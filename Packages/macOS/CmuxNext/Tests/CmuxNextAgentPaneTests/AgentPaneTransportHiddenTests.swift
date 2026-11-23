import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A pane nobody can see gets none of its chat's stream, and reads it when it shows (AcpmuxPaneSocket+Hidden.swift).
/// Leo's NIGHTLY (2026-11-21): 214 chat tabs, a few streaming; every record of a hidden chat still reached its page, so
/// its JSON crossed the main thread once (the Chromium push), whether anyone saw the chat or not.
struct AgentPaneTransportHiddenTests {
    private static func socket() throws -> AcpmuxPaneSocket {
        let url = try #require(URL(string: "ws://127.0.0.1"))
        return AcpmuxPaneSocket(request: URLRequest(url: url), limits: AgentPaneTransport.Limits(),
                                options: AcpmuxPermissionOptions(), sessions: AcpmuxPaneSessions(), ids: AcpmuxRequestIds(),
                                signal: {})
    }

    private static func chunk(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"kind":"agent_message_chunk","record":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}}"#
    }

    private static func update(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk"},"_meta":{"acpmux":{"seq":\#(seq)}}}}"#
    }

    private static func drain(_ socket: AcpmuxPaneSocket) -> [String] {
        socket.waitForInboundPasses()
        var frames: [String] = []
        while true {
            let batch = socket.take(maximumFrames: 512, maximumBytes: 64 << 20)
            frames += batch.frames
            if !batch.more { break }
        }
        return frames
    }

    private static func markers(_ frames: [String]) -> [[String: Any]] {
        frames.compactMap { frame in
            guard frame.contains(#""_acpmux/lagged""#),
                  let object = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any] else { return nil }
            return object["params"] as? [String: Any]
        }
    }

    @Test func aHiddenPaneGetsNoStreamAndReadsItWhenShown() throws {
        let socket = try Self.socket()
        socket.setHidden(true)
        for seq in 1...200 { socket.receiveLocalReply(Self.chunk(seq)) }
        for seq in 201...210 { socket.receiveLocalReply(Self.update(seq)) }
        let hidden = Self.drain(socket)
        // One start marker in the place of the first record left out; nothing of the stream.
        #expect(hidden.count == 1)
        let start = try #require(Self.markers(hidden).first)
        #expect(start["reason"] as? String == "host_hidden")
        #expect(start["phase"] as? String == "start")
        #expect(socket.hiddenShedCount == 210)

        // Shown: one end marker that names what was left out, and the stream flows again.
        socket.setHidden(false)
        let shown = Self.drain(socket)
        let end = try #require(Self.markers(shown).first)
        #expect(shown.count == 1)
        #expect(end["reason"] as? String == "host_hidden")
        #expect(end["phase"] == nil)
        #expect(end["dropped"] as? Int == 210)
        #expect(socket.hiddenShedCount == nil)
        socket.receiveLocalReply(Self.chunk(211))
        #expect(Self.drain(socket) == [Self.chunk(211)])
    }

    /// Prompts must not time out and Stop must end while nobody sees the pane: what the page waits on still goes.
    @Test func aHiddenPaneStillGetsWhatItWaitsOn() throws {
        let socket = try Self.socket()
        socket.setHidden(true)
        let accepted = #"{"jsonrpc":"2.0","method":"_acpmux/prompt_accepted","params":{"promptId":"p1"}}"#
        let request = #"{"jsonrpc":"2.0","id":"q1","method":"session/request_permission","params":{"sessionId":"s"}}"#
        let permission = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":3,"kind":"permission_request"}}"#
        let turnEnd = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":5,"kind":"turn_end"}}"#
        let turnResult = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":6,"kind":"turn_result"}}"#
        let queued = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":7,"kind":"queued"}}"#
        let dequeued = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":8,"kind":"dequeued"}}"#
        let refused = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":9,"kind":"prompt_refused"}}"#
        // A list notice is no stream record: it still goes.
        let listChanged = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"s"}}"#
        let kept = [accepted, request, permission, turnEnd, turnResult, queued, dequeued, refused, listChanged]
        socket.receiveLocalReply(Self.chunk(1))
        for frame in kept { socket.receiveLocalReply(frame) }
        socket.receiveLocalReply(Self.chunk(10))
        let frames = Self.drain(socket)
        for frame in [accepted, permission, turnEnd, turnResult, queued, dequeued, refused, listChanged] {
            #expect(frames.contains(frame))
        }
        #expect(frames.contains { $0.contains("session/request_permission") })
        #expect(!frames.contains(Self.chunk(1)))
        #expect(!frames.contains(Self.chunk(10)))
        #expect(Self.markers(frames).count == 1)
        #expect(socket.hiddenShedCount == 2)
    }

    @Test func hiddenAgainBeforeTheEndRanKeepsOneEpisode() throws {
        let socket = try Self.socket()
        socket.setHidden(true)
        socket.receiveLocalReply(Self.chunk(1))
        _ = Self.drain(socket)
        socket.setHidden(false)
        socket.setHidden(true)
        socket.receiveLocalReply(Self.chunk(2))
        let frames = Self.drain(socket)
        // Either the end ran before the second hide (an end and a new start) or after it (nothing): never a lost hole.
        let markers = Self.markers(frames)
        if markers.isEmpty {
            #expect(socket.hiddenShedCount == 2)
        } else {
            #expect(markers.count == 2)
            #expect(markers.last?["phase"] as? String == "start")
            #expect(socket.hiddenShedCount == 1)
        }
        socket.setHidden(false)
        let end = Self.markers(Self.drain(socket))
        #expect(end.count == 1)
        #expect(end.first?["phase"] == nil)
    }

    /// The transport tells its socket both levels of sight (``AgentPaneSight``): a covered pane (its document still
    /// visible, so the page checks that its stream moves) keeps its stream and only loses other chats' rows; a hidden
    /// or frozen one loses its stream too.
    @MainActor @Test func theTransportShedsTheStreamOnlyForAHiddenOrFrozenPage() throws {
        let transport = AgentPaneTransport()
        let socket = try Self.socket()
        transport.socket = socket
        transport.pageSight = AgentPaneSight(unseen: true, hidden: false)
        socket.receiveLocalReply(Self.chunk(1))
        #expect(Self.drain(socket) == [Self.chunk(1)], "a covered pane lost its stream")
        transport.pageSight = AgentPaneSight(unseen: true, hidden: true)
        socket.receiveLocalReply(Self.chunk(2))
        #expect(Self.markers(Self.drain(socket)).count == 1)
        transport.pageSight = .seen
        #expect(Self.markers(Self.drain(socket)).first?["dropped"] as? Int == 1)
        transport.beforePageWork = {}
        socket.receiveLocalReply(Self.chunk(3))
        #expect(Self.markers(Self.drain(socket)).count == 1, "a frozen page got its stream")
        transport.beforePageWork = nil
        #expect(Self.markers(Self.drain(socket)).first?["dropped"] as? Int == 1)
    }

    /// A shown pane is untouched: no marker, no scan.
    @Test func aShownPaneGetsEveryRecord() throws {
        let socket = try Self.socket()
        for seq in 1...50 { socket.receiveLocalReply(Self.chunk(seq)) }
        let frames = Self.drain(socket)
        #expect(frames == (1...50).map(Self.chunk))
        #expect(socket.hiddenShedCount == nil)
    }
}
