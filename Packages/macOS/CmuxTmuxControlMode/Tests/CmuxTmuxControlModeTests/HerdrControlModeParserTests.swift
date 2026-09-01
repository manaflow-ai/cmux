import Foundation
import Testing
@testable import CmuxTmuxControlMode

@Suite("Herdr terminal control parser")
struct HerdrControlModeParserTests {
    @Test("decodes a full frame and a closed record")
    func decodesFramesAndClose() {
        var parser = HerdrControlModeParser()
        let encoded = Data("screen\n".utf8).base64EncodedString()
        let bytes = Array("{\"type\":\"terminal.frame\",\"seq\":4,\"width\":80,\"height\":24,\"full\":true,\"bytes\":\"\(encoded)\"}\n{\"type\":\"terminal.closed\",\"reason\":\"released\"}\n".utf8)
        let events = parser.consume(bytes)
        let expected: [HerdrControlModeEvent] = [
            .frame(bytes: Array("screen\n".utf8), sequence: 4, width: 80, height: 24, full: true),
            .closed(reason: "released"),
        ]
        #expect(events == expected)
    }

    @Test("keeps partial JSON lines until the next chunk")
    func buffersPartialLine() {
        var parser = HerdrControlModeParser()
        let encoded = Data("x".utf8).base64EncodedString()
        let line = Array("{\"type\":\"terminal.frame\",\"bytes\":\"\(encoded)\"}\n".utf8)
        #expect(parser.consume(Array(line.prefix(8))).isEmpty)
        #expect(parser.consume(Array(line.dropFirst(8))).count == 1)
    }

    @Test("preserves an unsigned sequence and rejects malformed JSON")
    func preservesUnsignedSequenceAndRejectsMalformedRecord() {
        var parser = HerdrControlModeParser()
        let max = #"{"type":"terminal.frame","seq":18446744073709551615,"bytes":"YQ==","width":80,"height":24,"full":true}"#
        #expect(parser.consume(Array((max + "\n").utf8)) == [
            .frame(bytes: [0x61], sequence: UInt64.max, width: 80, height: 24, full: true)
        ])
        let malformed = parser.consume(Array("not-json\n".utf8))
        guard case .protocolError(let reason) = malformed.first else {
            Issue.record("expected a Herdr protocol error")
            return
        }
        #expect(reason.contains("invalid herdr control JSON"))
    }

    @Test("accepts the alternate sequence and size field spellings")
    func acceptsProtocolAliases() {
        var parser = HerdrControlModeParser()
        let line = #"{"type":"terminal.frame","sequence":9,"cols":100,"rows":30,"full":true,"bytes":""}"# + "\n"
        #expect(parser.consume(Array(line.utf8)) == [
            .frame(bytes: [], sequence: 9, width: 100, height: 30, full: true)
        ])
    }
}
