import Foundation
import Testing
@testable import CmuxNextDaemon

/// ``LineRouteScan``: the routing fields read from a line's bytes match what ``LineTransport/Envelope`` decodes,
/// and every line the scan could read differently is given up to the decoder.
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
        #"{"stream":3,"event":"output","surface":1,"data":"YQ=="}"#,
        #"{"event":"stream-end","stream":65535,"reason":"canceled"}"#,
        #"{"stream":65536,"event":"output"}"#,
        #"{"stream":"3","event":"output"}"#,
        #"{"stream":3,"id":4,"ok":true}"#,
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
        #expect(scan.stream == envelope.stream)
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
        #"{"event":"output","stream":-1}"#,
        #"{"event":"output","stream":3.0}"#,
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
}
