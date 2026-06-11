import Testing
@testable import CmuxTmuxControlMode

@Suite("tmux control mode parser")
struct TmuxControlModeParserTests {
    private func parse(_ s: String) -> [TmuxControlModeEvent] {
        var parser = TmuxControlModeParser()
        return parser.consume(Array(s.utf8))
    }

    @Test func decodesOutputAndUnescapesOctal() {
        // \033]0;t\007hi  -> ESC ] 0 ; t BEL h i
        let events = parse("%output %1 \\033]0;t\\007hi\n")
        #expect(events == [.output(paneID: "%1", bytes: [0x1B, 0x5D, 0x30, 0x3B, 0x74, 0x07, 0x68, 0x69])])
    }

    @Test func unescapesBackslashItself() {
        // tmux escapes a literal backslash as \134
        let events = parse("%output %2 a\\134b\n")
        #expect(events == [.output(paneID: "%2", bytes: [0x61, 0x5C, 0x62])])
    }

    @Test func outputDataMayContainSpaces() {
        let events = parse("%output %0 hello world\n")
        #expect(events == [.output(paneID: "%0", bytes: Array("hello world".utf8))])
    }

    @Test func commandBlockAggregatesOutputLines() {
        let events = parse("%begin 100 7 1\nline one\nline two\n%end 100 7 1\n")
        #expect(events == [
            .begin(number: 7),
            .commandResult(number: 7, output: ["line one", "line two"], isError: false),
        ])
    }

    @Test func errorBlockIsFlagged() {
        let events = parse("%begin 1 3 1\nboom\n%error 1 3 1\n")
        #expect(events == [
            .begin(number: 3),
            .commandResult(number: 3, output: ["boom"], isError: true),
        ])
    }

    @Test func notificationLinesInsideBlockAreTreatedAsOutput() {
        // The "notifications never appear inside a block" invariant means a line
        // that merely looks like a notification is command output here.
        let events = parse("%begin 1 1 1\n%this-is-data\n%end 1 1 1\n")
        #expect(events == [
            .begin(number: 1),
            .commandResult(number: 1, output: ["%this-is-data"], isError: false),
        ])
    }

    @Test func decodesLayoutChange() {
        let events = parse("%layout-change @0 b25f,80x24,0,0,1 b25f,80x24,0,0,1 *\n")
        #expect(events == [.layoutChange(window: "@0", layout: "b25f,80x24,0,0,1", visibleLayout: "b25f,80x24,0,0,1", flags: "*")])
    }

    @Test func decodesExitAndDetach() {
        #expect(parse("%exit\n") == [.exit(reason: nil)])
        #expect(parse("%exit server exited\n") == [.exit(reason: "server exited")])
        #expect(parse("%client-detached client-1\n") == [.clientDetached])
    }

    @Test func handlesCRLFLineEndings() {
        let events = parse("%output %1 hi\r\n")
        #expect(events == [.output(paneID: "%1", bytes: Array("hi".utf8))])
    }

    @Test func buffersPartialLinesAcrossChunks() {
        var parser = TmuxControlModeParser()
        #expect(parser.consume(Array("%output %1 he".utf8)).isEmpty)
        let events = parser.consume(Array("llo\n".utf8))
        #expect(events == [.output(paneID: "%1", bytes: Array("hello".utf8))])
    }

    @Test func ignoresStrayNonProtocolLinesOutsideBlock() {
        // The DCS / leftover terminal noise before the protocol settles.
        let events = parse("garbage line\n%output %1 ok\n")
        #expect(events == [.output(paneID: "%1", bytes: Array("ok".utf8))])
    }

    @Test func stripsControlModeEntryDcsFusedToFirstBegin() {
        // tmux emits the entry DCS fused to the first %begin on the wire.
        let events = parse("\u{1b}P1000p%begin 1 5 0\nok\n%end 1 5 0\n")
        #expect(events == [
            .begin(number: 5),
            .commandResult(number: 5, output: ["ok"], isError: false),
        ])
    }

    @Test func stripsTrailingStringTerminatorOnExit() {
        let events = parse("%exit\u{1b}\\\n")
        #expect(events == [.exit(reason: nil)])
    }

    @Test func decodesExtendedOutput() {
        let events = parse("%extended-output %1 5 : data\n")
        #expect(events == [.output(paneID: "%1", bytes: Array("data".utf8))])
    }
}
