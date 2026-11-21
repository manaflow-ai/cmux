import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Each daemon frame is read once (``AcpmuxJSONKeys/facts(_:)``): the duplicate-key check, its
/// top-level `method` and `id`, and its `params.kind`. Before, the inbound pass searched the
/// frame's text again with Foundation `contains` for up to 15 markers to decide whether a hidden
/// page waits on it, and 3 more for the permission records: 75% of each pane socket's inbound
/// queue in Leo's NIGHTLY (2026-11-21), ten queues at 10-14% each.
struct AcpmuxFrameFactsTests {
    @Test func factsReadTheTopLevelMethodIdAndParamsKind() {
        let event = AcpmuxJSONKeys.facts(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","msg":{"kind":"x"},"kind":"turn_end"}}"#)
        #expect(event.verdict == .clean)
        #expect(event.hasMethod && event.method == "_acpmux/event" && !event.hasID && event.kind == "turn_end")

        let reply = AcpmuxJSONKeys.facts(#"{"jsonrpc":"2.0","id":4,"result":{"method":"m","params":{"kind":"k"}}}"#)
        #expect(reply.verdict == .clean && !reply.hasMethod && reply.method == nil && reply.hasID && reply.kind == nil)

        // A nested `kind` or `method` is not the frame's.
        let nested = AcpmuxJSONKeys.facts(#"{"method":"session/update","params":{"update":{"kind":"turn_end","method":"x"}}}"#)
        #expect(nested.method == "session/update" && nested.kind == nil)

        // Escaped spellings read as what they decode to.
        let escaped = AcpmuxJSONKeys.facts(#"{"method":"_acpmux\/event","params":{"kind":"turn_end"}}"#)
        #expect(escaped.method == "_acpmux/event" && escaped.kind == "turn_end")

        // A method that is not a string is still a method.
        let numeric = AcpmuxJSONKeys.facts(#"{"method":5,"params":[{"kind":"turn_end"}]}"#)
        #expect(numeric.hasMethod && numeric.method == nil && numeric.kind == nil)

        #expect(AcpmuxJSONKeys.facts(#"{"method":"a","method":"b"}"#).verdict == .duplicate)
        #expect(AcpmuxJSONKeys.facts(#"{"method":"a""#).verdict == .malformed)
        #expect(AcpmuxJSONKeys.facts("").verdict == .malformed)
    }

    /// The single read decides what the old text search did, on every frame shape the pacer cares
    /// about, and no longer wakes a page for a marker inside a transcript.
    @Test func classifyWaitsOnlyForDeliveryBoundaries() {
        let ids = AcpmuxRequestIds()
        func waits(_ text: String) -> Bool { ids.classify(text).waits }
        for kind in AcpmuxPaneSocket.waitedEventKinds {
            #expect(waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","kind":"\#(kind)"}}"#))
        }
        #expect(waits(#"{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"sessionId":"s"}}"#))
        #expect(!waits(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","kind":"agent_message"}}"#))
        // A transcript that quotes a marker (an agent reading this file) is not a boundary.
        #expect(!waits(#"{"jsonrpc":"2.0","method":"session/update","params":{"text":"\"kind\":\"turn_end\" \"_acpmux/prompt_accepted\""}}"#))
        #expect(!waits(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"kind":"turn_end","session":{}}}"#))
    }

    /// Only the permission records are parsed for the host's observers, by their `params.kind`.
    @Test func eventsAreParsedOnlyForObservedKinds() {
        let ids = AcpmuxRequestIds()
        for kind in AcpmuxRequestIds.observedEventKinds {
            let text = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","dir":"mux","kind":"\#(kind)","msg":{}}}"#
            guard case .page(let forwarded, let object, let method) = ids.toPage(text) else {
                Issue.record("event was not forwarded")
                continue
            }
            #expect(forwarded == text && object != nil && method == "_acpmux/event")
        }
        let quoted = #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"kind":"agent_message","msg":{"text":"permission_request"}}}"#
        guard case .page(_, let object, let method) = ids.toPage(quoted) else {
            Issue.record("event was not forwarded")
            return
        }
        #expect(object == nil && method == "_acpmux/event")
        #expect(AcpmuxPaneShedding.sheddable(quoted))
        #expect(!AcpmuxPaneShedding.sheddable(#"{"method":"_acpmux/event","params":{"kind":"permission_request"}}"#))
    }

    /// A `_acpmux/session_changed` the size Leo's watch feed carried (~45 KB, 2026-11-21), and a
    /// transcript chunk with non-ASCII text.
    static func frames() -> [String] {
        let span = #"{"turnSeq":1203,"turnId":"t-01a1fb75","category":"model","startAt":1795000000000,"endAt":1795000004211,"tokens":5123,"turnTokens":40211}"#
        let spans = Array(repeating: span, count: 300).joined(separator: ",")
        let changed = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"s","kind":"status","recordKind":"status","seq":418026,"listSeq":620190,"session":{"sessionId":"s","name":"claude-sr2","status":"running","title":"Fix the starved threads","timeBreakdown":{"totalMs":1,"tokensComplete":true,"categories":[],"spans":["# + spans + #"]}}}}"#
        return [changed, AcpmuxPaneInboundNativeTests.chunk(bytes: 20_480)]
    }

    /// The detector for this class: classifying a frame costs one read of it, not one read per
    /// marker. Bound: at most the cost of the four Foundation `contains` misses the old `pageWaits`
    /// alone spent on a `session_changed` frame (the check came on top of that). Prints ns per frame
    /// for the PR's table.
    @Test(arguments: [0, 1])
    func classifyingAFrameCostsOneRead(index: Int) {
        let frame = Self.frames()[index]
        let ids = AcpmuxRequestIds()
        let rounds = 200
        let markers = [#""_acpmux/prompt_accepted""#, #""session/request_permission""#, #""_acpmux/event""#, #""kind":"turn_end""#]
        var sink = 0
        let classify = ContinuousClock().measure {
            for _ in 0..<rounds where ids.classify(frame).waits { sink += 1 }
        }
        let search = ContinuousClock().measure {
            for _ in 0..<rounds { for marker in markers where frame.contains(marker) { sink += 1 } }
        }
        let perFrame = { (d: Duration) in (d / rounds).components.attoseconds / 1_000_000_000 }
        print("frame \(frame.utf8.count) B: classify \(perFrame(classify)) ns/frame, 4 Foundation contains \(perFrame(search)) ns/frame (sink \(sink))")
        #expect(classify < search)
    }
}
