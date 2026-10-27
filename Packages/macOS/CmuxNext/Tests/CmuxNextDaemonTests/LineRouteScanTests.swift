import Foundation
import Testing
@testable import CmuxNextDaemon

/// ``LineRouteScan``: the routing fields read from a line's bytes match what ``LineTransport/Envelope`` decodes,
/// and every line the scan could read differently is given up to the decoder (p05-ipc-090).
@Suite struct LineRouteScanTests {
    private static func scan(_ line: String) -> LineRouteScan? { LineRouteScan(Data(line.utf8)) }

    private static func decoded(_ line: String) -> LineTransport.Envelope? {
        try? WireCoding.decoder().decode(LineTransport.Envelope.self, from: Data(line.utf8))
    }

    /// Lines the daemon writes: each scans to the fields the decoder reads.
    @Test(arguments: [
        #"{"id":7,"ok":true,"data":{"a":[1,2.5e-3,{"b":"c\"d\\eé"}],"n":null,"t":true,"f":false}}"#,
        #"{"id":"42","ok":false,"error":{"code":"x","message":"m","retryable":true}}"#,
        #"{"ok":false,"error":"bad request"}"#,
        #"{"event":"tree-changed","cause":"program","data":{"id":5,"ok":true}}"#,
        #"{"type":"stream_item","stream_id":"s1","sequence":3,"item":{"event":"nested"}}"#,
        #"{"type":"stream_end","stream_id":"s1","reason":"gap"}"#,
        #"  { "id" : 0 , "ok" : true }  "#,
        #"{"id":18446744073709551615,"ok":true}"#,
        #"{"id":18446744073709551616,"ok":true}"#,
        #"{"id":true,"ok":1,"event":5,"type":null}"#,
        #"{"cause":"frontend","id":3}"#,
        #"{}"#,
        #"{"title":"é✓😀","event":"title-changed"}"#,
    ])
    func daemonLinesScanAsTheyDecode(line: String) throws {
        let scan = try #require(Self.scan(line), "the scan gave up \(line)")
        let envelope = try #require(Self.decoded(line), "the decoder refused \(line)")
        #expect(scan.id == envelope.id)
        #expect(scan.ok == envelope.ok)
        #expect(scan.event == envelope.event)
        #expect(scan.type == envelope.type)
        #expect(scan.streamID == envelope.streamID)
        #expect(scan.cause == envelope.cause)
    }

    /// Lines the scan could read differently from the decoder, or that are not one JSON object: given up.
    @Test(arguments: [
        #"{"ev\u0065nt":"x"}"#,
        #"{"event":"a\"b"}"#,
        #"{"id":1,"id":2}"#,
        #"{"id":1.0,"ok":true}"#,
        #"{"id":-1,"ok":true}"#,
        #"{"id":1e2,"ok":true}"#,
        #"{"id":01,"ok":true}"#,
        #"{"ok":true,"x":"\ud800"}"#,
        #"{"ok":tru}"#,
        #"{"ok":true,}"#,
        #"{"ok":true} x"#,
        #"[{"ok":true}]"#,
        #"{]"#,
        #"{"ok":true"#,
        "",
        String(repeating: "[", count: 70) + String(repeating: "]", count: 70),
        "{\"x\":" + String(repeating: "[", count: 70) + String(repeating: "]", count: 70) + "}",
    ])
    func ambiguousLinesAreGivenUp(line: String) {
        #expect(Self.scan(line) == nil, "the scan read \(line)")
    }

    /// A deep but allowed value is skipped, not given up.
    @Test func nestingUpToTheLimitIsSkipped() throws {
        let depth = LineRouteScan.maxDepth - 1
        let line = #"{"id":9,"x":"# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        #expect(Self.scan(line)?.id == 9)
    }

    /// An event's `flow` (the key press an `output` echoes) is read with the routing fields, so the reader marks
    /// the echo's handoff before it decodes the line (p09-observability-102); a value the decoder would read
    /// differently, or a `flow` outside an event, is no flow, and the line still routes.
    @Test func anEventsFlowIsRead() throws {
        let flow: UInt64 = 0x1234 << 32 | 7
        let echo = try #require(Self.scan(#"{"event":"output","surface":3,"data":"YQ==","flow":\#(flow)}"#))
        #expect(echo.event == "output")
        #expect(echo.flow == flow)
        #expect(Self.scan(#"{"event":"output","flow":18446744073709551615}"#)?.flow == UInt64.max)
        for line in [#"{"event":"output","data":"YQ=="}"#, #"{"event":"output","flow":1.5}"#,
                     #"{"event":"output","flow":18446744073709551616}"#, #"{"event":"output","flow":"7"}"#,
                     #"{"id":4,"ok":true,"flow":7}"#] {
            let scan = try #require(Self.scan(line), "the scan gave up \(line)")
            #expect(scan.flow == nil, "\(line)")
        }
    }
}
