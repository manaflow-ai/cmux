import Foundation
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

    @Test("does not truncate out-of-range octal values")
    func preservesOutOfRangeOctalLiteral() {
        let events = parse("%output %2 a\\400b\\777c\\134\n")
        #expect(events == [
            .output(paneID: "%2", bytes: Array("a\\400b\\777c\\".utf8))
        ])
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

    @Test("a fence for another command stays pane content")
    func mismatchedFenceDoesNotDesynchronizeCapture() {
        let events = parse("%begin 1 9 1\n%end 1 8 1\nrow\n%end 1 9 1\n")
        #expect(events == [
            .begin(number: 9),
            .commandResult(number: 9, output: ["%end 1 8 1", "row"], isError: false),
        ])
    }

    @Test("all guard metadata must match before a block closes")
    func mismatchedFenceMetadataStaysPayload() {
        let events = parse("%begin 10 9 1\n%end 11 9 1\nrow\n%end 10 9 1\n")
        #expect(events == [
            .begin(number: 9),
            .commandResult(number: 9, output: ["%end 11 9 1", "row"], isError: false),
        ])
    }

    @Test("malformed fences fail closed")
    func malformedBeginProducesProtocolError() {
        let events = parse("%begin not-a-number\n")
        #expect(events == [.protocolError(reason: "malformed tmux %begin fence")])
    }

    @Test("malformed output notifications fail closed")
    func malformedOutputProducesProtocolError() {
        var parser = TmuxControlModeParser()
        #expect(parser.consume(Array("%output missing-pane\n".utf8)) == [
            .protocolError(reason: "malformed tmux %output notification")
        ])
        #expect(parser.consume(Array("%output %1 ignored\n".utf8)).isEmpty)
    }

    @Test("malformed extended output metadata fails closed")
    func malformedExtendedOutputProducesProtocolError() {
        var parser = TmuxControlModeParser()
        #expect(parser.consume(Array("%extended-output %1 nope : data\n".utf8)) == [
            .protocolError(reason: "malformed tmux %extended-output age")
        ])
    }

    @Test("command blocks have a bounded memory budget")
    func oversizedBlockProducesProtocolError() {
        var parser = TmuxControlModeParser(maxCommandBlockBytes: 4)
        let events = parser.consume(Array("%begin 1 1 1\n1234\n".utf8))
        #expect(events == [
            .begin(number: 1),
            .protocolError(reason: "tmux control block exceeded 4 bytes"),
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

    @Test func decodesSubscriptionValueAfterMetadata() {
        let events = parse("%subscription-changed cmux_harbor_reflow_3 1 @0 %3 : 0|zsh\n")
        #expect(events == [.subscriptionChanged(name: "cmux_harbor_reflow_3", value: "0|zsh")])
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

    @Test func decodesExtendedOutput() {
        let events = parse("%extended-output %1 5 : data\n")
        #expect(events == [.output(paneID: "%1", bytes: Array("data".utf8))])
    }

    @Test("accepts reserved extended-output metadata after the age")
    func decodesExtendedOutputWithFutureMetadata() {
        let events = parse("%extended-output %1 5 future-field another-field : data\n")
        #expect(events == [.output(paneID: "%1", bytes: Array("data".utf8))])
    }

    @Test("strips the DCS wrapper used by tmux -CC over a forced SSH tty")
    func decodesDCSFramedControlStream() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        let enter = Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        var bytes = Array(enter)
        bytes.append(contentsOf: Array("%begin 1 4 0\n%end 1 4 0\n%exit done\n".utf8))
        bytes.append(contentsOf: [0x1B, 0x5C])
        #expect(parser.consume(bytes) == [
            .begin(number: 4),
            .commandResult(number: 4, output: [], isError: false),
            .exit(reason: "done"),
        ])
    }

    @Test("accepts startup pty noise before the DCS marker")
    func toleratesScriptStartupNoise() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        var bytes: [UInt8] = [0x04, 0x08, 0x08]
        bytes.append(contentsOf: [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        bytes.append(contentsOf: Array("%exit done\n".utf8))
        bytes.append(contentsOf: [0x1B, 0x5C])
        #expect(parser.consume(bytes) == [.exit(reason: "done")])
    }

    @Test("synchronizes when the DCS marker crosses transport chunks")
    func synchronizesAcrossSplitDCSMarker() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        #expect(parser.consume([0x04, 0x1B, 0x50, 0x31]).isEmpty)
        var second = Array("000p%exit done\n".utf8)
        second.append(contentsOf: [0x1B, 0x5C])
        #expect(parser.consume(second) == [.exit(reason: "done")])
        #expect(parser.finish().isEmpty)
    }

    @Test("accepts a DCS terminator delivered after the final newline")
    func acceptsStandaloneDCSTerminatorAtEOF() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        var bytes = Array([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        bytes.append(contentsOf: Array("%exit done\n".utf8))
        #expect(parser.consume(bytes) == [.exit(reason: "done")])
        #expect(parser.consume([0x1B]).isEmpty)
        #expect(parser.consume([0x5C]).isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test("does not parse protocol-looking text before the DCS marker")
    func ignoresProtocolLookingPreamble() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        #expect(parser.consume(Array("%exit forged\n".utf8)).isEmpty)
        var framed = Array([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        framed.append(contentsOf: Array("%exit real\n".utf8))
        framed.append(contentsOf: [0x1B, 0x5C])
        #expect(parser.consume(framed) == [.exit(reason: "real")])
        #expect(parser.finish().isEmpty)
    }

    @Test("rejects EOF before the DCS marker")
    func rejectsMissingDCSStart() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        #expect(parser.consume(Array("ssh banner\n".utf8)).isEmpty)
        #expect(parser.finish() == [
            .protocolError(reason: "tmux control stream ended before DCS framing began")
        ])
    }

    @Test("rejects EOF before the DCS terminator")
    func rejectsMissingDCSEnd() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        var bytes = Array([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        bytes.append(contentsOf: Array("%exit done\n".utf8))
        #expect(parser.consume(bytes) == [.exit(reason: "done")])
        #expect(parser.finish() == [
            .protocolError(reason: "tmux control stream ended before DCS framing closed")
        ])
    }

    @Test("flushes an unterminated exit record at EOF")
    func finishesPartialLine() {
        var parser = TmuxControlModeParser()
        #expect(parser.consume(Array("%exit done".utf8)).isEmpty)
        #expect(parser.finish() == [.exit(reason: "done")])
    }

    @Test("normalizes CR on an EOF-terminated control record")
    func finishesPartialCRLFLine() {
        var parser = TmuxControlModeParser()
        _ = parser.consume(Array("%exit done\r".utf8))
        #expect(parser.finish() == [.exit(reason: "done")])
    }

    @Test("fails when EOF cuts a command block")
    func failsPartialCommandBlock() {
        var parser = TmuxControlModeParser()
        _ = parser.consume(Array("%begin 1 2 1\nrow\n".utf8))
        #expect(parser.finish() == [.protocolError(reason: "tmux control stream ended inside a command block")])
    }

    @Test("does not strip an OSC terminator from raw pane output")
    func preservesStringTerminatorInOutput() {
        var parser = TmuxControlModeParser(stripDCSFraming: true)
        var bytes = Array([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        bytes.append(contentsOf: Array("%output %1 ".utf8))
        bytes.append(contentsOf: [0x1B, 0x5C])
        bytes.append(0x0A)
        #expect(parser.consume(bytes) == [.output(paneID: "%1", bytes: [0x1B, 0x5C])])
    }
}
