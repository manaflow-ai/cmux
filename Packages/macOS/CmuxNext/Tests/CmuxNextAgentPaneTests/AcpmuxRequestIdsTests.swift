import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxRequestIdsTests {
    @Test func opaqueNotificationKeepsWireTextAndSkipsFoundationParse() throws {
        let text = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("notification was not forwarded")
            return
        }
        #expect(forwarded == text)
        #expect(object == nil)
        #expect(method == nil)
    }

    @Test func observerNotificationKeepsWireTextButProvidesParsedObject() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("observer notification was not forwarded")
            return
        }
        #expect(forwarded == text)
        #expect(method == "_acpmux/permission_pending")
        #expect((object?["params"] as? [String: Any])?["permissionId"] as? String == "p")
    }

    @Test func observerMethodValueIsUsedInsteadOfSubstringMarkers() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"message":"_acpmux/event"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("observer notification was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func escapedObserverMethodValueStillFeedsObservers() throws {
        let text = #"{"jsonrpc":"2.0","method":"_acpmux\/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("escaped observer notification was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func escapedObserverMethodKeyStillFeedsObservers() throws {
        let text = #"{"jsonrpc":"2.0","\u006det\u0068od":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p"}}"#
        let ids = AcpmuxRequestIds()
        guard case .page(_, let object, let method) = ids.toPage(text) else {
            Issue.record("escaped observer method key was not forwarded")
            return
        }
        #expect(method == "_acpmux/permission_pending")
        #expect(object != nil)
    }

    @Test func replyWithMethodInResultStillRewritesItsId() throws {
        let text = #"{"jsonrpc":"2.0","id":1,"result":{"value":"method","nested":{"method":"opaque"}}}"#
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "7", method: "_acpmux/status"))
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("reply was mistaken for a notification")
            return
        }
        #expect(method == "_acpmux/status")
        #expect(object?["id"] as? Int == 7)
        #expect(forwarded.contains(#""id":7"#))
        #expect(relay == 1)
    }

    /// An `_acpmux/events` page of transcript records, with escapes inside its values only.
    static func eventsPage(id: Int, kind: String = "transcript") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"events":[{"sessionId":"s","seq":4,"dir":"mux","kind":"\#(kind)","msg":{"text":"a \"quoted\" line\nand a slash \/ é"}}],"more":true}}"#
    }

    @Test func historyPageWithoutPermissionRecordsPassesThroughUnparsed() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: #""page-9""#, method: "_acpmux/events"))
        let text = Self.eventsPage(id: relay)
        guard case .reply(let forwarded, let method) = ids.toPage(text) else {
            Issue.record("a history page no observer reads was parsed")
            return
        }
        #expect(method == "_acpmux/events")
        // The daemon's own text, its escapes as they were, with only the id swapped.
        #expect(forwarded == text.replacingOccurrences(of: #""id":\#(relay),"#, with: #""id":"page-9","#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(forwarded.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "page-9")
        // The page id is free again.
        #expect(ids.begin(pageID: #""page-9""#, method: "_acpmux/events") != nil)
    }

    @Test func historyPageWithAPermissionRecordFeedsObservers() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "12", method: "_acpmux/events"))
        let text = Self.eventsPage(id: relay, kind: "permission_request")
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("a history page with a permission record was not parsed")
            return
        }
        #expect(method == "_acpmux/events")
        #expect(object?["id"] as? Int == 12)
        #expect(forwarded == text.replacingOccurrences(of: #""id":\#(relay),"#, with: #""id":12,"#))
    }

    @Test func parsedReplyKeepsTheDaemonTextWithThePageId() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "5", method: "_acpmux/attach"))
        let text = #"{"jsonrpc":"2.0","result":{"session":{"sessionId":"s","cwd":"/tmp"},"events":[{"msg":{"text":"x\ny"}}]},"id":\#(relay)}"#
        guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
            Issue.record("attach reply not forwarded")
            return
        }
        #expect(method == "_acpmux/attach")
        #expect(object?["id"] as? Int == 5)
        #expect(forwarded == text.replacingOccurrences(of: #""id":\#(relay)}"#, with: #""id":5}"#))
    }

    @Test func escapedIdKeyStillRewritesThroughTheParse() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "8", method: "_acpmux/events"))
        let text = #"{"jsonrpc":"2.0","\u0069d":\#(relay),"result":{"events":[]}}"#
        guard case .page(let forwarded, let object, _) = ids.toPage(text) else {
            Issue.record("escaped id key reply not forwarded through the parse")
            return
        }
        #expect(object?["id"] as? Int == 8)
        let reparsed = try #require(try JSONSerialization.jsonObject(with: Data(forwarded.utf8)) as? [String: Any])
        #expect(reparsed["id"] as? Int == 8)
    }

    @Test func nestedIdIsNotTheRelayId() throws {
        let ids = AcpmuxRequestIds()
        let relay = try #require(ids.begin(pageID: "3", method: "_acpmux/events"))
        let text = #"{"jsonrpc":"2.0","result":{"events":[{"id":999,"kind":"transcript"}]},"id":\#(relay)}"#
        guard case .reply(let forwarded, _) = ids.toPage(text) else {
            Issue.record("history page not passed through")
            return
        }
        #expect(forwarded.contains(#"{"id":999,"#))
        #expect(forwarded.hasSuffix(#""id":3}"#))
    }

    @MainActor @Test func passedThroughReplyWakesAHiddenPage() async throws {
        let (woken, wake) = AsyncStream<Void>.makeStream()
        let transport = AgentPaneTransport()
        let ids = AcpmuxRequestIds()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            limits: transport.limits,
            options: transport.permissionOptions,
            sessions: transport.sessions,
            ids: ids,
            signal: { wake.yield() })
        let relay = try #require(ids.begin(pageID: "4", method: "_acpmux/events"))
        socket.receiveLocalReply(Self.eventsPage(id: relay))
        for await _ in woken { break }
        #expect(socket.pageWaits)
        #expect(socket.answersWaiting)
        let batch = socket.take(maximumFrames: 10, maximumBytes: 1 << 20)
        #expect(batch.frames.count == 1)
    }

    /// `_acpmux/request_state` (webviews direct.ts `checkRequests`): the daemon's relay ids come
    /// back as the page's, and `relayed` names only requests written before the question, so one
    /// the host still holds (a confirmation sheet) is never judged lost.
    @Test func requestStateAnswersInPageIdsAndNamesOnlyWrittenRequests() throws {
        let ids = AcpmuxRequestIds()
        let created = try #require(ids.begin(pageID: "7", method: "session/new"))
        ids.written(created)
        let held = try #require(ids.begin(pageID: "8", method: "session/prompt"))
        let question = try #require(ids.begin(pageID: "9", method: AcpmuxRequestIds.requestStateMethod))
        ids.snapshotWritten(for: question)
        ids.written(question)
        // Written after the question: the daemon had not read it, so the answer says nothing of it.
        let late = try #require(ids.begin(pageID: "10", method: "session/set_model"))
        ids.written(late)
        let text = #"{"jsonrpc":"2.0","id":\#(question),"result":{"running":[\#(created),\#(held),99],"answered":[]}}"#
        guard case .page(let forwarded, _, let method) = ids.toPage(text) else {
            Issue.record("the answer did not reach the page")
            return
        }
        #expect(method == AcpmuxRequestIds.requestStateMethod)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(forwarded.utf8)) as? [String: Any])
        #expect(object["id"] as? Int == 9)
        let result = try #require(object["result"] as? [String: Any])
        // 99 is another relay's request on the daemon's connection: never the page's.
        #expect(result["running"] as? [Int] == [7, 8])
        #expect(result["answered"] as? [Int] == [])
        #expect(result["relayed"] as? [Int] == [7])
    }
}
