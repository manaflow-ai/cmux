import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone asks the Mac for compact chunks (`_acpmux/chunk`) and row patches
/// (`_acpmux/session_patch`), and reads them back into exactly the records and rows the whole
/// forms gave (`AcpmuxDeltas`): chunks by `seq` with no text lost or doubled, patches applied to
/// the row held, and a resync on an unknown `ref` or a patch whose base is not the row held.
@MainActor
@Suite struct AcpmuxDeltaTests {
    // MARK: The wire, both ways

    nonisolated static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    nonisolated static func encode(_ value: JSONValue) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    /// A streamed text chunk's `_acpmux/event` params, as the whole form carries it.
    static func chunkEvent(seq: Int, at: Int, text: String, segment: Int = 1) -> JSONValue {
        json(#"""
        {"sessionId":"s1","seq":\#(seq),"at":\#(at),"dir":"in","kind":"agent_message_chunk",
         "msg":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"agent-1",
          "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":\#(encode(.string(text)))}},
          "_meta":{"acpmux":{"segment":\#(segment)}}}}}
        """#)
    }

    /// A tool call between chunks: never compact, and it leaves the chat's template as it was.
    static func toolEvent(seq: Int, at: Int) -> JSONValue {
        json(#"""
        {"sessionId":"s1","seq":\#(seq),"at":\#(at),"dir":"in","kind":"tool_call",
         "msg":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"agent-1",
          "update":{"sessionUpdate":"tool_call","toolCallId":"c\#(seq)","title":"ls","status":"pending"}}}}
        """#)
    }

    /// One streamed answer as the whole form sends it: chunks every 50 ms, a tool call in the
    /// middle, then a new reply segment (its chunks match the old template in no way).
    static let wholeStream: [JSONValue] = {
        var out: [JSONValue] = []
        var at = 1_795_000_000_000
        for seq in 2...40 {
            at += 50
            switch seq {
            case 15: out.append(toolEvent(seq: seq, at: at))
            case 16...: out.append(chunkEvent(seq: seq, at: at, text: "w\(seq) ", segment: 2))
            default: out.append(chunkEvent(seq: seq, at: at, text: seq == 3 ? "" : "w\(seq) é ", segment: 1))
            }
        }
        return out
    }()

    /// The same stream as `server/chunk_deltas.rs` sends it to a client that asked: per chat, a
    /// chunk whose record matches the last full chunk event in all but `seq`, `at` and the text
    /// goes as `_acpmux/chunk`; anything else as the event, a chunk event with a new `chunkRef`.
    static func compact(_ events: [JSONValue]) -> [(method: String, params: JSONValue)] {
        var out: [(String, JSONValue)] = []
        var template: (ref: Int, shape: JSONValue, seq: Double, at: Double)?
        var nextRef = 0
        func shape(_ v: JSONValue) -> JSONValue {
            guard case .object(var o) = v else { return v }
            o["seq"] = nil
            o["at"] = nil
            let text = AcpmuxDeltas.apply(json(#"{"msg":{"params":{"update":{"content":{"text":null}}}}}"#), to: .object(o))!
            return text
        }
        for event in events {
            guard event["kind"]?.stringValue == "agent_message_chunk", let text = event["msg"]?["params"]?["update"]?["content"]?["text"]?.stringValue else {
                out.append(("_acpmux/event", event))
                continue
            }
            let seq = event["seq"]!.numberValue!, at = event["at"]!.numberValue!
            if let t = template, seq > t.seq, at >= t.at, t.shape == shape(event) {
                out.append(("_acpmux/chunk", .object(["ref": .number(Double(t.ref)), "seq": .number(seq),
                                                      "dt": .number(at - t.at), "text": .string(text)])))
                template = (t.ref, t.shape, seq, at)
                continue
            }
            nextRef += 1
            template = (nextRef, shape(event), seq, at)
            guard case .object(var o) = event else { continue }
            o["chunkRef"] = .number(Double(nextRef))
            out.append(("_acpmux/event", .object(o)))
        }
        return out
    }

    // MARK: Chunks

    @Test func compactChunksReadBackIntoTheWholeEvents() {
        var deltas = AcpmuxDeltas()
        let frames = Self.compact(Self.wholeStream)
        #expect(frames.filter { $0.method == "_acpmux/chunk" }.count >= 30)
        var read: [JSONValue] = []
        for frame in frames {
            if frame.method == "_acpmux/event" {
                read.append(deltas.event(frame.params))
            } else if case let .event(sessionID, params) = deltas.chunk(frame.params) {
                #expect(sessionID == "s1")
                read.append(params)
            } else {
                Issue.record("a known ref read as unknown: \(frame.params)")
            }
        }
        #expect(read == Self.wholeStream)
    }

    @Test func aChunkOfARefNeverHeardIsAResync() {
        var deltas = AcpmuxDeltas()
        #expect(deltas.chunk(Self.json(#"{"ref":7,"seq":3,"dt":50,"text":"x"}"#)) == .unknownRef)
        // A chat's new ref retires its old one: the Mac keeps one template per chat.
        var first = Self.chunkEvent(seq: 2, at: 10, text: "a")
        if case .object(var o) = first { o["chunkRef"] = .number(1); first = .object(o) }
        _ = deltas.event(first)
        var second = Self.chunkEvent(seq: 3, at: 20, text: "b", segment: 2)
        if case .object(var o) = second { o["chunkRef"] = .number(2); second = .object(o) }
        #expect(deltas.event(second) == Self.chunkEvent(seq: 3, at: 20, text: "b", segment: 2))
        #expect(deltas.chunk(Self.json(#"{"ref":1,"seq":4,"dt":5,"text":"c"}"#)) == .unknownRef)
        #expect(deltas.chunk(Self.json(#"{"ref":2,"seq":4,"dt":5,"text":"c"}"#))
            == .event(sessionID: "s1", params: Self.chunkEvent(seq: 4, at: 25, text: "c", segment: 2)))
    }

    // MARK: Rows

    /// A chat's row as a long turn moves it: the status, the preview, a time breakdown whose
    /// spans grow at the end and drop the oldest, a key that goes away.
    static func row(_ n: Int) -> JSONValue {
        let spans = (max(0, n - 6)...n).map { #"{"kind":"model","ms":\#($0 * 10)}"# }.joined(separator: ",")
        let gone = n < 3 ? #","indicator":"working""# : ""
        return json(#"""
        {"sessionId":"s1","name":"Fix","harness":"claude","cwd":"/tmp/w","status":"\#(n % 2 == 0 ? "running" : "idle")",
         "preview":"step \#(n)","lastSeq":\#(100 + n),"pendingPermissions":0,"turnCount":\#(n),
         "timeBreakdown":{"spans":[\#(spans)]},"tools":["Read","Edit"]\#(gone)}
        """#)
    }

    /// `row(n - 1)` to `row(n)` as `server/session_patch.rs` diffs it.
    static func patch(_ n: Int) -> JSONValue {
        let from = max(0, n - 6) - max(0, n - 7)
        let keep = (max(0, n - 6)...(n - 1)).count
        let gone = n == 3 ? #","indicator":null"# : ""
        return json(#"""
        {"status":"\#(n % 2 == 0 ? "running" : "idle")","preview":"step \#(n)","lastSeq":\#(100 + n),"turnCount":\#(n),
         "timeBreakdown":{"spans":{"$splice":[\#(from),\#(keep),[{"kind":"model","ms":\#(n * 10)}]]}}\#(gone)}
        """#)
    }

    @Test func patchesTakeTheHeldRowToTheWholeOne() {
        var deltas = AcpmuxDeltas()
        let first = Self.json(#"{"sessionId":"s1","kind":"updated","recordKind":"agent_message_chunk","seq":101,"rowSeq":1}"#)
        guard case .object(var o) = first else { return }
        o["session"] = Self.row(1)
        _ = deltas.changed(.object(o))
        for n in 2...12 {
            let params = Self.json(#"{"sessionId":"s1","kind":"updated","recordKind":"agent_message_chunk","seq":\#(100 + n),"listSeq":\#(n),"rowSeq":\#(n),"baseRowSeq":\#(n - 1)}"#)
            guard case .object(var p) = params else { return }
            p["patch"] = Self.patch(n)
            guard case let .changed(changed) = deltas.patch(.object(p)) else {
                Issue.record("patch \(n) read as a gap")
                return
            }
            #expect(changed["session"] == Self.row(n), "row \(n)")
            #expect(changed["patch"] == nil && changed["baseRowSeq"] == nil)
            #expect(changed["recordKind"]?.stringValue == "agent_message_chunk")
        }
    }

    @Test func aPatchOnAnotherBaseIsAGapUntilTheNextWholeRow() {
        var deltas = AcpmuxDeltas()
        guard case .object(var o) = Self.json(#"{"sessionId":"s1","kind":"updated","rowSeq":4}"#) else { return }
        o["session"] = Self.row(4)
        _ = deltas.changed(.object(o))
        func patch(_ n: Int, base: Int) -> JSONValue {
            guard case .object(var p) = Self.json(#"{"sessionId":"s1","kind":"updated","rowSeq":\#(n),"baseRowSeq":\#(base)}"#) else { return .null }
            p["patch"] = Self.patch(n)
            return .object(p)
        }
        // Row 5 was lost: 6 applies to a row this phone does not hold.
        #expect(deltas.patch(patch(6, base: 5)) == .gap(sessionID: "s1"))
        #expect(deltas.heldRow("s1") == nil)
        #expect(deltas.patch(patch(7, base: 6)) == .gap(sessionID: "s1"))
        // A patch before any row, and a `$splice` past the array held, are gaps too.
        var fresh = AcpmuxDeltas()
        #expect(fresh.patch(patch(2, base: 1)) == .gap(sessionID: "s1"))
        #expect(AcpmuxDeltas.apply(Self.json(#"{"a":{"$splice":[2,5,[]]}}"#), to: Self.json(#"{"a":[1,2]}"#)) == nil)
    }

    // MARK: Through the hub

    /// What the Mac was asked, and the notifications it sends after the attach and watch replies.
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var initialize: JSONValue?
        private var watched = 0
        let afterAttach: [(String, JSONValue)]
        let afterWatch: [(String, JSONValue)]
        init(afterAttach: [(String, JSONValue)] = [], afterWatch: [(String, JSONValue)] = []) {
            self.afterAttach = afterAttach
            self.afterWatch = afterWatch
        }
        var initializeParams: JSONValue? { lock.withLock { initialize } }
        var watches: Int { lock.withLock { watched } }

        func link() -> MockMacLink {
            MockMacLink { [self] _, data in
                guard let object = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let method = object["method"]?.stringValue else { return [] }
                let id = object["id"].map(AcpmuxDeltaTests.encode) ?? "null"
                func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
                func notes(_ list: [(String, JSONValue)]) -> [Data] {
                    list.map { Data(#"{"jsonrpc":"2.0","method":"\#($0.0)","params":\#(AcpmuxDeltaTests.encode($0.1))}"#.utf8) }
                }
                switch method {
                case "initialize":
                    lock.withLock { initialize = object["params"] }
                    return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"capabilities":["session-changed-delta-v1"]}}}"#)]
                case "_acpmux/watch":
                    let first = lock.withLock { () -> Bool in
                        watched += 1
                        return watched == 1
                    }
                    let list = reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"claude","cwd":"/tmp/w","status":"idle","lastSeq":1}]}"#)
                    return first ? [list] + notes(afterWatch) : [list]
                case "_acpmux/attach":
                    return [reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":1,"events":[]}"#)]
                        + notes(afterAttach)
                default: return [reply("{}")]
                }
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s1", name: "Fix", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")

    static func waitUntil(_ done: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(20)
        while !done(), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(5)) // test: polls the condition, bounded above
        }
    }

    @Test func initializeAsksForBothCompactForms() async throws {
        let mac = Mac()
        let hub = AcpmuxHub()
        await hub.bind(try await mac.link().openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        let meta = mac.initializeParams?["_meta"]?["acpmux"]
        #expect(meta?["chunkDeltas"] == .bool(true))
        #expect(meta?["sessionChangedDelta"] == .bool(true))
    }

    /// The chat applies the same records, in the same order, from the compact stream as from the
    /// whole one.
    @Test func anOpenChatAppliesTheSameRecordsFromCompactChunks() async throws {
        func journal(_ frames: [(String, JSONValue)]) async throws -> [JSONValue] {
            let hub = AcpmuxHub()
            await hub.bind(try await Mac(afterAttach: frames).link().openChannel(service: "acpmux", args: [:]))
            let source = hub.source(sessionID: "s1", summary: Self.summary)
            let store = AgentChatStore(source: source)
            await Self.waitUntil { source.journal.events.count >= Self.wholeStream.count }
            _ = store
            return source.journal.events.map(\.record)
        }
        let whole = try await journal(Self.wholeStream.map { ("_acpmux/event", $0) })
        let compact = try await journal(Self.compact(Self.wholeStream))
        #expect(whole == Self.wholeStream)
        #expect(compact == whole)
    }

    /// The hub's row of a chat is the same from patches as from whole rows.
    @Test func theHubsRowIsTheSameFromPatches() async throws {
        let notice = Self.json(#"{"sessionId":"s1","kind":"updated","recordKind":"agent_message_chunk","seq":101}"#)
        func with(_ extra: [String: JSONValue]) -> JSONValue {
            guard case .object(var o) = notice else { return notice }
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let whole = (1...8).map { ("_acpmux/session_changed", with(["session": Self.row($0)])) }
        let patched = [("_acpmux/session_changed", with(["session": Self.row(1), "rowSeq": .number(1)]))]
            + (2...8).map { ("_acpmux/session_patch", with(["patch": Self.patch($0), "rowSeq": .number(Double($0)), "baseRowSeq": .number(Double($0 - 1))])) }
        func row(_ frames: [(String, JSONValue)]) async throws -> AcpmuxSession? {
            let hub = AcpmuxHub()
            await hub.bind(try await Mac(afterWatch: frames).link().openChannel(service: "acpmux", args: [:]))
            await Self.waitUntil { hub.sessions["s1"]?.preview == "step 8" }
            return hub.sessions["s1"]
        }
        let fromWhole = try await row(whole)
        let fromPatches = try await row(patched)
        #expect(fromWhole?.preview == "step 8")
        #expect(fromPatches == fromWhole)
    }

    /// A chunk of a ref the phone never heard has the open chat read on from its last record
    /// (a second attach), so its text comes from the Mac's log instead of being guessed.
    @Test func anUnknownRefAttachesTheOpenChatAgain() async throws {
        let attaches = Attaches()
        let hub = AcpmuxHub()
        let link = MockMacLink { _, data in
            guard let object = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let method = object["method"]?.stringValue else { return [] }
            let id = object["id"].map(AcpmuxDeltaTests.encode) ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[]}"#)]
            case "_acpmux/attach":
                let n = attaches.add()
                let page = reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":1,"events":[]}"#)
                return n == 1 ? [page, Data(#"{"jsonrpc":"2.0","method":"_acpmux/chunk","params":{"ref":9,"seq":2,"dt":50,"text":"lost"}}"#.utf8)] : [page]
            default: return [reply("{}")]
            }
        }
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        await Self.waitUntil { attaches.count >= 2 }
        #expect(attaches.count == 2)
        _ = store
    }

    /// A patch on a base the phone does not hold recovers the channel once: the next connection
    /// starts the Mac's side again, whole rows first.
    @Test func aRowGapRecoversTheChannelOnce() async throws {
        let notice = Self.json(#"{"sessionId":"s1","kind":"updated","rowSeq":3,"baseRowSeq":2,"patch":{"preview":"x"}}"#)
        let hub = AcpmuxHub()
        let recoveries = Attaches()
        hub.onStall = { _ = recoveries.add() }
        await hub.bind(try await Mac(afterWatch: [("_acpmux/session_patch", notice), ("_acpmux/session_patch", notice)])
            .link().openChannel(service: "acpmux", args: [:]))
        await Self.waitUntil { recoveries.count >= 1 }
        try? await Task.sleep(for: .milliseconds(100)) // test: lets a second recovery show, if any
        #expect(recoveries.count == 1)
        #expect(hub.sessions["s1"]?.preview != "x")
    }

    final class Attaches: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() -> Int { lock.withLock { n += 1; return n } }
        var count: Int { lock.withLock { n } }
    }
}
