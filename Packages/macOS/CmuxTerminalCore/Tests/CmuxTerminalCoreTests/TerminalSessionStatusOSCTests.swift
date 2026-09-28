import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Session status escape sequence (OSC 21337)")
struct TerminalSessionStatusOSCTests {
    private func parsedUpdates(_ chunks: [String]) -> [TerminalSessionStatusUpdate] {
        var scanner = TerminalSessionStatusOSCScanner()
        return chunks.flatMap { scanner.consume(Data($0.utf8)) }
    }

    private func resolvedStatus(_ chunks: [String]) -> TerminalSessionStatus {
        var status = TerminalSessionStatus()
        for update in parsedUpdates(chunks) {
            status.apply(update)
        }
        return status
    }

    @Test("A BEL-terminated sequence sets status and indicator")
    func belTerminatedSequence() {
        let status = resolvedStatus(["before\u{1B}]21337;status=Working;indicator=#ffa500\u{07}after"])

        #expect(status.status == "Working")
        #expect(status.indicator == "#ffa500")
        #expect(status.displayText == "Working")
        #expect(status.displayColor == "#ffa500")
    }

    @Test("An ESC backslash terminator ends the sequence")
    func stringTerminatorSequence() {
        let status = resolvedStatus(["\u{1B}]21337;status=Done;detail=3 files\u{1B}\\"])

        #expect(status.status == "Done")
        #expect(status.detail == "3 files")
    }

    @Test("A sequence split across PTY reads at every byte is parsed once")
    func sequenceSplitAcrossReads() {
        let sequence = "\u{1B}]21337;status=Thinking;detail=step 2\u{07}"
        let chunks = sequence.unicodeScalars.map { String($0) }

        let parsed = parsedUpdates(chunks)

        #expect(parsed.count == 1)
        #expect(parsed.first?.status == "Thinking")
        #expect(parsed.first?.detail == "step 2")
    }

    @Test("Colors accept #RRGGBB and rgb:RR/GG/BB and normalize to lowercase hex")
    func colorForms() {
        let status = resolvedStatus([
            "\u{1B}]21337;status=Busy;indicator=rgb:FF/a5/00;status-color=#00FF7F\u{07}",
        ])

        #expect(status.indicator == "#ffa500")
        #expect(status.statusColor == "#00ff7f")
    }

    @Test("Malformed colors are ignored instead of clearing the previous color")
    func malformedColorsAreIgnored() {
        let status = resolvedStatus([
            "\u{1B}]21337;status=Busy;indicator=#ffa500\u{07}",
            "\u{1B}]21337;indicator=orange;status-color=#12345\u{07}",
            "\u{1B}]21337;indicator=rgb:ff/a5\u{07}",
            "\u{1B}]21337;indicator=#gg0000\u{07}",
        ])

        #expect(status.indicator == "#ffa500")
        #expect(status.statusColor == nil)
    }

    @Test("Status color is used when no indicator is set")
    func statusColorFallback() {
        let status = resolvedStatus(["\u{1B}]21337;status=Idle;status-color=#336699\u{07}"])

        #expect(status.displayColor == "#336699")
    }

    @Test("An empty value clears only that key; absent keys keep their values")
    func emptyValueClearsOneKey() {
        let status = resolvedStatus([
            "\u{1B}]21337;status=Working;indicator=#ffa500;detail=build\u{07}",
            "\u{1B}]21337;indicator=\u{07}",
        ])

        #expect(status.status == "Working")
        #expect(status.detail == "build")
        #expect(status.indicator == nil)
        #expect(status.isVisible)
    }

    @Test("Clearing status and detail hides the entry")
    func clearingEverythingHidesEntry() {
        let status = resolvedStatus([
            "\u{1B}]21337;status=Working;indicator=#ffa500;detail=build\u{07}",
            "\u{1B}]21337;status=;indicator=;status-color=;detail=\u{07}",
        ])

        #expect(status == TerminalSessionStatus())
        #expect(!status.isVisible)
        #expect(status.displayText == nil)
    }

    @Test("Detail joins the status text, and shows alone without a status")
    func detailDisplay() {
        #expect(resolvedStatus(["\u{1B}]21337;status=Working;detail=npm test\u{07}"]).displayText == "Working · npm test")
        #expect(resolvedStatus(["\u{1B}]21337;detail=npm test\u{07}"]).displayText == "npm test")
    }

    @Test("Unknown keys and items without '=' are ignored")
    func unknownKeysIgnored() {
        let parsed = parsedUpdates([
            "\u{1B}]21337;badge=7;status=Ok;noequals;url=https://example.com\u{07}",
            "\u{1B}]21337;badge=7;url=https://example.com\u{07}",
        ])

        #expect(parsed == [TerminalSessionStatusUpdate(status: "Ok")])
    }

    @Test("A value keeps '=' characters after the first one")
    func valueKeepsEquals() {
        #expect(resolvedStatus(["\u{1B}]21337;status=a=b\u{07}"]).status == "a=b")
    }

    @Test("Text is stripped of control characters and capped")
    func textSanitizedAndCapped() {
        let longStatus = String(repeating: "x", count: TerminalSessionStatus.maximumStatusCharacters + 50)
        let longDetail = String(repeating: "y", count: TerminalSessionStatus.maximumDetailCharacters + 50)
        let status = resolvedStatus([
            "\u{1B}]21337;status=\(longStatus);detail=\(longDetail)\u{07}",
        ])

        #expect(status.status?.count == TerminalSessionStatus.maximumStatusCharacters)
        #expect(status.detail?.count == TerminalSessionStatus.maximumDetailCharacters)
        #expect(resolvedStatus(["\u{1B}]21337;status= a\u{08}b\u{7F}c \u{07}"]).status == "abc")
        #expect(resolvedStatus(["\u{1B}]21337;status=\u{08}\u{07}"]).isVisible == false)
    }

    @Test("An oversized payload is dropped and the next sequence still parses")
    func oversizedPayloadDropped() {
        let oversized = String(repeating: "z", count: TerminalSessionStatusOSCScanner.maximumPayloadBytes + 1)
        let parsed = parsedUpdates([
            "\u{1B}]21337;status=\(oversized)\u{07}",
            "\u{1B}]21337;status=Next\u{07}",
        ])

        #expect(parsed == [TerminalSessionStatusUpdate(status: "Next")])
    }

    @Test("Other OSC numbers and look-alike prefixes are ignored")
    func otherOSCIgnored() {
        let parsed = parsedUpdates([
            "\u{1B}]2;status=Title\u{07}",
            "\u{1B}]213370;status=Nope\u{07}",
            "\u{1B}]2133;status=Nope\u{07}",
            "\u{1B}]1337;SetUserVar=status=Tm9wZQ==\u{07}",
            "\u{1B}[31mstatus=red\u{1B}[0m",
        ])

        #expect(parsed.isEmpty)
    }

    @Test("An escape inside the payload aborts it and a following sequence parses")
    func escapeAbortsPayload() {
        let parsed = parsedUpdates([
            "\u{1B}]21337;status=Half\u{1B}[0m\u{1B}]21337;status=Whole\u{07}",
            "\u{1B}]21337;status=Cancelled\u{18}\u{1B}]21337;detail=d\u{07}",
        ])

        #expect(parsed == [
            TerminalSessionStatusUpdate(status: "Whole"),
            TerminalSessionStatusUpdate(detail: "d"),
        ])
    }

    @Test("A bare OSC 21337 with no pairs changes nothing")
    func emptyPayload() {
        #expect(parsedUpdates(["\u{1B}]21337\u{07}", "\u{1B}]21337;\u{07}"]).isEmpty)
    }

    @Test("Bidi overrides, format characters and line separators are stripped")
    func formatAndSeparatorScalarsStripped() {
        let status = resolvedStatus([
            "\u{1B}]21337;status=\u{202E}gnikroW\u{202C};detail=a\u{2028}b\u{2029}c\u{200B}d\u{07}",
        ])

        #expect(status.status == "gnikroW")
        #expect(status.detail == "abcd")
    }

    @Test("An oversized payload split across reads is skipped to its ESC backslash terminator")
    func oversizedPayloadAcrossReads() {
        let filler = String(repeating: "z", count: TerminalSessionStatusOSCScanner.maximumPayloadBytes)
        let parsed = parsedUpdates([
            "\u{1B}]21337;status=\(filler)",
            "\(filler);detail=\u{07}still inside? no",
            "\u{1B}]21337;status=Late",
            "\(filler)\(filler)\u{1B}\\",
            "\u{1B}]21337;status=After\u{1B}\\",
        ])

        #expect(parsed == [TerminalSessionStatusUpdate(status: "After")])
    }
}
