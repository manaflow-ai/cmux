import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The cost of the reply id swap (ad349, round 6): a full JSON parse and re-encode of a reply against
/// the top-level scanner, on real-shaped large replies and on the small notification of the burst
/// bench. Runs only under scripts/measure/pane-native-transport.sh (the bench's switch).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH"] == "1"))
struct AgentPaneTransportBenchParse {
    /// An `_acpmux/events` page: `count` transcript events of about `textBytes` of text each.
    nonisolated static func eventsPage(count: Int, textBytes: Int) -> String {
        let text = String(repeating: "lorem ipsum dolor sit amet, \\\"quoted\\\" and \\u00e9 ", count: textBytes / 48)
        let event = { (seq: Int) in
            #"{"sessionId":"s-1","seq":\#(seq),"at":1759650000000,"kind":"transcript","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}}"#
        }
        return #"{"jsonrpc":"2.0","id":41,"result":{"events":["# + (0..<count).map(event).joined(separator: ",") + #"],"more":true,"lastSeq":\#(count)}}"#
    }

    /// A `session/load` style replay: tool calls whose outputs are large strings.
    nonisolated static func replay(calls: Int, outputBytes: Int) -> String {
        let output = String(repeating: "0123456789abcdef/path/to/file.swift:42: warning\\n", count: outputBytes / 48)
        let call = { (n: Int) in
            #"{"sessionUpdate":"tool_call_update","toolCallId":"t\#(n)","status":"completed","content":[{"type":"content","content":{"type":"text","text":"\#(output)"}}],"rawOutput":{"stdout":"\#(output)","exitCode":0}}"#
        }
        return #"{"jsonrpc":"2.0","id":42,"result":{"updates":["# + (0..<calls).map(call).joined(separator: ",") + "]}}"
    }

    nonisolated static func full(_ text: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        guard object["method"] == nil else { return text }
        object["id"] = 7
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func scanned(_ text: String) -> String? {
        guard let scan = AcpmuxEnvelope.scan(Array(text.utf8)) else { return nil }
        if scan.hasMethod { return text }
        return AcpmuxRequestIds.withID("7", in: text)
    }

    /// Median and maximum milliseconds of `runs` runs.
    nonisolated static func time(_ runs: Int, _ body: () -> String?) -> (median: Double, max: Double) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            precondition(body() != nil)
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        return (samples[samples.count / 2], samples.last ?? 0)
    }

    @Test func theIdSwapCost() {
        let frames: [(String, String, Int)] = [
            ("notification-300B", #"{"jsonrpc":"2.0","method":"session/update","params":{"s":12,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(String(repeating: "x", count: 200))"}}}}"#, 2000),
            ("events-1MB", Self.eventsPage(count: 1000, textBytes: 1000), 20),
            ("events-5MB", Self.eventsPage(count: 5000, textBytes: 1000), 10),
            ("replay-10MB", Self.replay(calls: 100, outputBytes: 50_000), 10),
            ("replay-30MB", Self.replay(calls: 300, outputBytes: 50_000), 5),
        ]
        for (name, text, runs) in frames {
            #expect(Self.full(text) != nil && Self.scanned(text) != nil, "\(name)")
            let full = Self.time(runs) { Self.full(text) }
            let scan = Self.time(runs) { Self.scanned(text) }
            print(String(format: "PANE-PARSE %@ bytes=%d full_ms=%.3f full_max_ms=%.3f scan_ms=%.3f scan_max_ms=%.3f",
                         name, text.utf8.count, full.median, full.max, scan.median, scan.max))
        }
    }
}
