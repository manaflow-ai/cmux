import Foundation
import Testing
@testable import CmuxTmuxControlMode

@Suite("Zellij rendered session protocol")
struct ZellijRenderedSessionTests {
    @Test("decodes a JSON record and preserves ANSI lines")
    func decodesPaneUpdate() {
        var parser = ZellijRenderedSessionParser()
        let json = "{\"event\":\"pane_update\",\"pane_id\":\"terminal_7\",\"viewport\":[\"\\u001b[31mred\\u001b[0m\",\"prompt $\"],\"scrollback\":[\"old\"],\"is_initial\":true}\n"
        #expect(parser.consume(Array(json.utf8)) == [
            .update(
                paneID: "terminal_7",
                viewport: ["\u{1B}[31mred\u{1B}[0m", "prompt $"],
                scrollback: ["old"],
                isInitial: true
            )
        ])
    }

    @Test("accepts records split across transport chunks")
    func buffersChunks() {
        var parser = ZellijRenderedSessionParser()
        let first = Array("{\"event\":\"pane_update\",\"pane_id\":\"terminal_1\",\"viewport\":[\"ok\"],\"is_initial\":false}\n".utf8)
        #expect(parser.consume(Array(first.prefix(20))).isEmpty)
        #expect(parser.consume(Array(first.dropFirst(20))) == [
            .update(paneID: "terminal_1", viewport: ["ok"], scrollback: nil, isInitial: false)
        ])
    }

    @Test("malformed known records fail closed")
    func malformedRecord() {
        var parser = ZellijRenderedSessionParser()
        let malformed = "{\"event\":\"pane_update\",\"pane_id\":\"terminal_1\",\"viewport\":[\"bad\nline\"],\"is_initial\":true}\n"
        let events = parser.consume(Array(malformed.utf8))
        guard case .protocolError(let reason) = events.first else {
            Issue.record("expected a protocol error")
            return
        }
        #expect(reason.contains("invalid zellij subscription JSON"))
        #expect(parser.consume(Array("{\"event\":\"pane_closed\",\"pane_id\":\"terminal_1\"}\n".utf8)).isEmpty)
    }

    @Test("decodes pane closure")
    func decodesClosed() {
        var parser = ZellijRenderedSessionParser()
        #expect(parser.consume(Array("{\"event\":\"pane_closed\",\"pane_id\":\"terminal_4\"}\n".utf8)) == [
            .closed(paneID: "terminal_4")
        ])
    }

    @Test("renders a complete replacement frame")
    func rendersFrame() {
        let bytes = ZellijRenderedSessionGateway.renderFrame(
            scrollback: ["old"],
            viewport: ["one", "two"]
        )
        #expect(bytes.starts(with: TerminalSessionSnapshot.replacementPrefix))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("old\r\n"))
        #expect(text.contains("\u{1B}[1;1Hone\u{1B}[K"))
        #expect(text.contains("\u{1B}[2;1Htwo\u{1B}[K"))
    }

    @Test("builds local and remote subscribe commands from one contract")
    func commandArguments() {
        #expect(ZellijRenderedSessionGateway.subscribeArguments(
            sessionName: "dev", paneID: "terminal_2", scrollbackLines: 12
        ) == [
            "--session", "dev", "subscribe", "--pane-id", "terminal_2",
            "--format", "json", "--ansi", "--scrollback", "12",
        ])
        let remote = ZellijRenderedSessionGateway.remoteSubscribeArguments(
            destination: "user@host", sessionName: "a'b", paneID: "terminal_2", scrollbackLines: 0
        )
        #expect(remote.first == "-T")
        #expect(remote[remote.count - 3] == "--")
        #expect(remote[remote.count - 2] == "user@host")
        #expect(remote.last?.contains("zellij") == true)
        #expect(remote.last?.contains("'a'\\''b'") == true)
    }
}
