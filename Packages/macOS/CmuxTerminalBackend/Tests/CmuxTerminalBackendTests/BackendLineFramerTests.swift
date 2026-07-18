import Foundation
import Testing
@testable import CmuxTerminalBackend

@Suite("Bounded backend line framing")
struct BackendLineFramerTests {
    @Test("an exact-limit message accepts its trailing newline separately")
    func exactLimit() throws {
        var framer = BackendLineFramer(maximumMessageBytes: 4)
        try framer.append(Data("1234".utf8))
        #expect(try framer.nextMessage() == nil)
        try framer.append(Data([0x0A]))
        #expect(try framer.nextMessage() == Data("1234".utf8))
    }

    @Test("a fragmented over-limit line fails before another read")
    func fragmentedOversize() throws {
        var framer = BackendLineFramer(maximumMessageBytes: 4)
        try framer.append(Data("1234".utf8))
        try framer.append(Data("5".utf8))
        #expect(throws: BackendProtocolError.oversizedMessage(limit: 4)) {
            try framer.nextMessage()
        }
    }

    @Test("several buffered lines preserve order and skip empty keepalives")
    func multipleLines() throws {
        var framer = BackendLineFramer(maximumMessageBytes: 16)
        try framer.append(Data("\nfirst\nsecond\n".utf8))
        #expect(try framer.nextMessage() == Data("first".utf8))
        #expect(try framer.nextMessage() == Data("second".utf8))
        #expect(try framer.nextMessage() == nil)
    }

    @Test("invalid UTF-8 is rejected without decoding JSON")
    func invalidUTF8() throws {
        var framer = BackendLineFramer(maximumMessageBytes: 4)
        try framer.append(Data([0xFF, 0x0A]))
        #expect(throws: BackendProtocolError.malformedMessage) {
            try framer.nextMessage()
        }
    }
}
