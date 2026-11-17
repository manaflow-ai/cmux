import Foundation
import Testing
@testable import CmuxNextDaemon

/// CMUX-571 goal terminal-throughput: an attach `output` line in a flood carries up to 1 MiB of terminal bytes as
/// base64. The app's reader thread must decode that base64 straight from the line, not run the JSON parser over it
/// (it did twice: the routing envelope, then the event).
@Suite struct AttachOutputLineDecodeTests {
    /// A JSON parser that counts the bytes it is handed.
    private final class CountingDecoder: JSONDecoder, @unchecked Sendable {
        private(set) var parsedBytes = 0
        override func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            parsedBytes += data.count
            return try super.decode(type, from: data)
        }
    }

    /// The line the daemon writes (`serialize_snapshot_output`: keys sorted, `colors` first when present).
    private static func outputLine(_ bytes: Data, surface: UInt64 = 7, generation: UInt64? = 3) -> Data {
        var text = #"{"data":""# + bytes.base64EncodedString() + #"","event":"output""#
        if let generation { text += #","generation":\#(generation),"offset":0"# }
        text += #","surface":\#(surface)}"#
        return Data(text.utf8)
    }

    private static let flood = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    @Test func aFloodLinesTerminalBytesNeverGoThroughTheJSONParser() throws {
        let line = Self.outputLine(Self.flood)
        let decoder = CountingDecoder()
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "output", line: line, surface: 7,
                                                                       decoder: decoder))
        #expect(decoded.event == .output(Self.flood, colors: nil))
        #expect(decoded.generation == 3)
        #expect(decoder.parsedBytes < 256,
                "the JSON parser read \(decoder.parsedBytes) bytes of a \(line.count)-byte output line")
    }

    @Test func anOutputLineOfAnotherSurfaceIsDropped() {
        let line = Self.outputLine(Data("hi".utf8), surface: 8)
        #expect(TerminalAttachment.decodeAttachLine(name: "output", line: line, surface: 7) == nil)
    }

    @Test func anOutputLineWithoutAGenerationDecodes() throws {
        let line = Self.outputLine(Data("plain".utf8), generation: nil)
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "output", line: line, surface: 7))
        #expect(decoded.event == .output(Data("plain".utf8), colors: nil))
        #expect(decoded.generation == nil)
    }

    @Test func anOutputLineInAnotherKeyOrderStillDecodes() throws {
        let line = Data(#"{"event":"output","surface":7,"data":"aGk="}"#.utf8)
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "output", line: line, surface: 7))
        #expect(decoded.event == .output(Data("hi".utf8), colors: nil))
    }

    @Test func anOutputLineWithBadBase64IsUndecodableNotEmpty() {
        let line = Data(#"{"data":"%%%","event":"output","surface":7}"#.utf8)
        #expect(TerminalAttachment.decodeAttachLine(name: "output", line: line, surface: 7) == nil)
    }
}
