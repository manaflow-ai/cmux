import Foundation
import Testing
@testable import CmuxAcpmux

struct LineFramerTests {
    @Test func splitsCompleteLinesAndKeepsTail() throws {
        var framer = LineFramer()
        let first = try framer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}"])
        let second = try framer.append(Data(":2}\n".utf8))
        #expect(second.map { String(decoding: $0, as: UTF8.self) } == ["{\"b\":2}"])
    }

    @Test func handlesManyLinesInOneChunkAndCRLF() throws {
        var framer = LineFramer()
        let frames = try framer.append(Data("1\r\n\n2\n3\n".utf8))
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["1", "2", "3"])
    }

    @Test func byteAtATimeProducesSameFrames() throws {
        var framer = LineFramer()
        var frames: [String] = []
        for byte in Data("{\"x\":\"é\"}\n{}\n".utf8) {
            frames += try framer.append(Data([byte])).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(frames == ["{\"x\":\"é\"}", "{}"])
    }

    @Test func rejectsOverlongLine() {
        var framer = LineFramer(maximumLineLength: 4)
        #expect(throws: LineFramerError.lineTooLong) {
            _ = try framer.append(Data("123456".utf8))
        }
    }

    @Test func decodesResponsesAndNotifications() throws {
        let response = try JSONRPCInbound.decode(Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8))
        #expect(response == .response(id: 3, result: .success(.object(["ok": .bool(true)]))))
        let failure = try JSONRPCInbound.decode(Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"nope"}}"#.utf8))
        #expect(failure == .response(id: 4, result: .failure(JSONRPCError(code: -32601, message: "nope"))))
        let note = try JSONRPCInbound.decode(Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"seq":1}}"#.utf8))
        #expect(note == .notification(method: "_acpmux/event", params: .object(["seq": .number(1)])))
    }
}
