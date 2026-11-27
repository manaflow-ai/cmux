import Foundation
import Testing
@testable import CmuxNextDaemon

/// The attach hot path reads an `output` line from one byte scan and a base64 decode straight from the line
/// (terminal-throughput: the line was JSON-parsed twice and base64-decoded through a String on one reader thread).
/// The scan must agree with the general decoder on every line it accepts, and refuse the lines it cannot read.
@Suite struct AttachLineScannerTests {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func plainOutputIsReadWithoutAJSONTree() throws {
        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        let json = #"{"data":"\#(bytes.base64EncodedString())","event":"output","generation":7,"surface":3}"#
        let fields = try #require(AttachLineScanner.scanOutput(line(json)))
        #expect(fields.event == "output")
        #expect(fields.data == bytes)
        #expect(fields.generation == 7)
        #expect(fields.surface == 3)
        #expect(!fields.hasType)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 255, 4096])
    func base64MatchesFoundationForEveryPaddingLength(count: Int) throws {
        let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) })
        let json = #"{"event":"output","data":"\#(bytes.base64EncodedString())"}"#
        let fields = try #require(AttachLineScanner.scanOutput(line(json)))
        #expect(fields.data == bytes)
    }

    @Test func theFastPathAndTheGeneralDecoderAgree() throws {
        let surface = SurfaceID(rawValue: 3)
        let bytes = Data("hello \u{1b}[31mred\u{1b}[0m\r\n".utf8)
        let json = #"{"event":"output","surface":3,"data":"\#(bytes.base64EncodedString())","generation":2}"#
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "output", line: line(json), surface: surface))
        #expect(decoded.event == .output(bytes, colors: nil))
        #expect(decoded.generation == 2)
        // Another surface's output is dropped, as before.
        let other = #"{"event":"output","surface":9,"data":"\#(bytes.base64EncodedString())"}"#
        #expect(TerminalAttachment.decodeAttachLine(name: "output", line: line(other), surface: surface) == nil)
    }

    @Test func linesItCannotReadFallBackToTheGeneralDecoder() {
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":"AA==","colors":{}}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":4}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":"AA="}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","event":"x","data":"AA=="}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":"AA==""#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"id":4,"ok":true,"data":{"a":[1,2]}}"#)) == nil)
    }

    @Test func routeEnvelopeNamesTheEventAndSkipsUnknownFields() throws {
        let json = #"{"extra":{"a":["}","\""],"b":1},"event":"scroll-changed","surface":1,"offset":4}"#
        let fields = try #require(AttachLineScanner.scanOutput(line(json), decodeData: false))
        #expect(fields.event == "scroll-changed")
        let streamed = try #require(AttachLineScanner.scanOutput(line(#"{"type":"stream_item","event":"x"}"#), decodeData: false))
        #expect(streamed.hasType)
    }

    @Test func badByteInTheMiddleOrEscapeRefusesTheLine() {
        let good = Data((0..<600).map { UInt8(truncatingIfNeeded: $0) }).base64EncodedString()
        var chars = Array(good)
        chars[100] = "*"
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":"\#(String(chars))"}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"event":"output","data":"AA\/A"}"#)) == nil)
        #expect(AttachLineScanner.scanOutput(line(#"{"data":"AA==","event":"output"}"#), decodeData: false)?.event == "output")
        #expect(AttachLineScanner.scanOutput(line(#"{"data":"A\"A","event":"output"}"#), decodeData: false)?.event == "output")
    }

    /// Timing, printed not asserted: 1000 lines of 64 KiB (an `output` burst) scanned and decoded.
    @Test func decodeCostOfABurst() throws {
        let payload = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
        let json = line(#"{"event":"output","surface":3,"generation":1,"data":"\#(payload.base64EncodedString())"}"#)
        let start = ContinuousClock.now
        for _ in 0..<1000 {
            let fields = try #require(AttachLineScanner.scanOutput(json))
            #expect(fields.data?.count == payload.count)
        }
        let elapsed = start.duration(to: .now)
        print("AttachLineScanner burst: 64 MiB decoded in \(elapsed)")
    }
}
