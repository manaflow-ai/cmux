@testable import CmuxLink
import Foundation
import Testing

/// Golden vectors shared with the Rust codec (lane B5). Regenerate with
/// `CMUX_UPDATE_LINK_FRAME_VECTORS=1 swift test --filter LinkFrameTests`.
@Suite("LinkFrame codec")
struct LinkFrameTests {
    struct Vector: Codable, Equatable {
        var name: String
        var hex: String
    }

    static let session = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    static let frames: [(String, LinkFrame)] = [
        ("hello_new", .hello(sessionID: session, epoch: 0)),
        ("hello_resume", .hello(sessionID: session, epoch: 0x0102_0304_0506_0708)),
        ("welcome_new", .welcome(epoch: 42, resumed: false)),
        ("welcome_resumed", .welcome(epoch: 42, resumed: true)),
        ("open_reliable", .open(
            channel: 1,
            descriptor: ChannelDescriptor(stream: "terminal/term_ab12", reliability: .reliableOrdered, priority: .render, budgetBytes: 262_144),
            cursorEpoch: 42, cursorRevision: 7
        )),
        ("open_partial", .open(
            channel: 3,
            descriptor: ChannelDescriptor(stream: "rd/cursor", reliability: .partial(maxLifetime: .milliseconds(50)), priority: .media, budgetBytes: 4096),
            cursorEpoch: 0, cursorRevision: 0
        )),
        ("open_unordered", .open(
            channel: 4,
            descriptor: ChannelDescriptor(stream: "ä/ü", reliability: .unreliableUnordered, priority: .input, budgetBytes: 1),
            cursorEpoch: 1, cursorRevision: 2
        )),
        ("open_ack", .openAck(channel: 1, epoch: 42, revision: 9)),
        ("data", .data(channel: 1, revision: 300, payload: Data("hi".utf8))),
        ("data_empty", .data(channel: 0xFFFF_FFFF, revision: UInt64.max, payload: Data())),
        ("ack", .ack(channel: 5, revision: 1_000)),
        ("close", .close(channel: 7)),
        ("gap_retention", .gap(channel: 1, resumeAfter: 99, reason: .retentionExceeded)),
        ("gap_epoch", .gap(channel: 2, resumeAfter: 0, reason: .newEpoch)),
        ("session_close_normal", .sessionClose(.normal)),
        ("session_close_unauthorized", .sessionClose(.unauthorized)),
    ]

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/link-frames.json")
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("encodes and decodes every golden vector")
    func goldenVectors() throws {
        let computed = Self.frames.map { Vector(name: $0.0, hex: Self.hex($0.1.encoded())) }
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_LINK_FRAME_VECTORS"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(computed).write(to: Self.fixtureURL)
        }
        let url = try #require(Bundle.module.url(forResource: "link-frames", withExtension: "json", subdirectory: "Fixtures"))
        let golden = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        #expect(golden == computed)
        for (vector, (_, frame)) in zip(golden, Self.frames) {
            #expect(try LinkFrame(decoding: Self.bytes(vector.hex)) == frame, "\(vector.name)")
        }
    }

    @Test("data frame overhead matches the constant")
    func dataOverhead() {
        let frame = LinkFrame.data(channel: 1, revision: 1, payload: Data(count: 100))
        #expect(frame.encoded().count == 100 + LinkFrame.dataOverhead)
    }

    @Test("rejects malformed frames")
    func malformed() {
        #expect(throws: LinkFrameError.truncated) { try LinkFrame(decoding: Data()) }
        #expect(throws: LinkFrameError.unsupportedVersion(2)) { try LinkFrame(decoding: Data([2, 1])) }
        #expect(throws: LinkFrameError.unknownKind(99)) { try LinkFrame(decoding: Data([1, 99])) }
        #expect(throws: LinkFrameError.truncated) { try LinkFrame(decoding: Data([1, 6, 1, 0])) }
        var trailing = LinkFrame.close(channel: 1).encoded()
        trailing.append(0)
        #expect(throws: LinkFrameError.trailingBytes) { try LinkFrame(decoding: trailing) }
        #expect(throws: LinkFrameError.invalidField("resumed")) {
            try LinkFrame(decoding: Data([1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 5]))
        }
    }
}
