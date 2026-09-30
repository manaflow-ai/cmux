import Foundation
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``ANSIArtParser``: SGR styling, escape stripping, and the
/// input caps that keep a hostile or mistaken art file from costing anything.
@Suite struct ANSIArtParserTests {
    private let parser = ANSIArtParser()
    private let esc = "\u{1B}"

    private func runs(_ art: ANSIArt?, line: Int = 0) -> [ANSIArtRun] {
        art?.lines[line].runs ?? []
    }

    @Test func plainTextKeepsLinesAndMeasuresTheWidestLine() throws {
        let art = try #require(parser.parse(" _  _\n| || |\n|_||_|\n"))
        #expect(art.lines.map(\.text) == [" _  _", "| || |", "|_||_|"])
        #expect(art.columnCount == 6)
        #expect(art.lines.allSatisfy { $0.runs.allSatisfy { $0.style == ANSIArtStyle() } })
    }

    @Test func basicAndBrightForegroundAndBackgroundColors() throws {
        let art = try #require(parser.parse("\(esc)[31mA\(esc)[92mB\(esc)[44mC\(esc)[103mD\(esc)[39;49mE"))
        let styles = runs(art).map(\.style)
        #expect(runs(art).map(\.text) == ["A", "B", "C", "D", "E"])
        #expect(styles[0].foreground == .indexed(1))
        #expect(styles[1].foreground == .indexed(10))
        #expect(styles[2].foreground == .indexed(10))
        #expect(styles[2].background == .indexed(4))
        #expect(styles[3].background == .indexed(11))
        #expect(styles[4] == ANSIArtStyle())
    }

    @Test func boldDimInverseAndReset() throws {
        let art = try #require(parser.parse("\(esc)[1;2;7mA\(esc)[22mB\(esc)[27mC\(esc)[1;31mD\(esc)[0mE\(esc)[1mF\(esc)[mG"))
        let styles = runs(art).map(\.style)
        #expect(styles[0].isBold && styles[0].isDim && styles[0].isInverse)
        #expect(!styles[1].isBold && !styles[1].isDim && styles[1].isInverse)
        #expect(!styles[2].isInverse)
        #expect(styles[3].isBold && styles[3].foreground == .indexed(1))
        #expect(styles[4] == ANSIArtStyle())
        #expect(styles[5].isBold)
        // `ESC[m` is an empty parameter list, which means reset.
        #expect(styles[6] == ANSIArtStyle())
    }

    @Test func extendedColorsUseSemicolonAndColonForms() throws {
        let art = try #require(parser.parse(
            "\(esc)[38;5;208mA\(esc)[48;5;17mB\(esc)[38;2;255;128;0mC\(esc)[48;2;1;2;3mD"
                + "\(esc)[0;38:2::10:20:30mE\(esc)[38:2:40:50:60mF\(esc)[38:5:99mG"
        ))
        let styles = runs(art).map(\.style)
        #expect(styles[0].foreground == .indexed(208))
        #expect(styles[1].background == .indexed(17))
        #expect(styles[2].foreground == .rgb(ANSIArtRGB(255, 128, 0)))
        #expect(styles[3].background == .rgb(ANSIArtRGB(1, 2, 3)))
        #expect(styles[4].foreground == .rgb(ANSIArtRGB(10, 20, 30)))
        #expect(styles[4].background == nil)
        #expect(styles[5].foreground == .rgb(ANSIArtRGB(40, 50, 60)))
        #expect(styles[6].foreground == .indexed(99))
    }

    @Test func extendedColorParametersAfterTheColorStillApply() throws {
        let art = try #require(parser.parse("\(esc)[38;5;1;1;48;2;9;9;9mA"))
        let style = try #require(runs(art).first?.style)
        #expect(style.foreground == .indexed(1))
        #expect(style.isBold)
        #expect(style.background == .rgb(ANSIArtRGB(9, 9, 9)))
    }

    @Test func malformedSGRKeepsTheValidPrefixAndDropsTheRest() throws {
        // Out-of-range and truncated extended colors stop the sequence rather
        // than guessing; the text stays and earlier parameters still apply.
        let art = try #require(parser.parse(
            "\(esc)[1;38;5;300mA\(esc)[0m\(esc)[38;2;1;2mB\(esc)[0m\(esc)[99999999999999999999;31mC\(esc)[0m\(esc)[38mD"
        ))
        let parsed = runs(art)
        #expect(parsed.map(\.text).joined() == "ABCD")
        #expect(parsed[0].style.isBold)
        #expect(parsed[0].style.foreground == nil)
        #expect(parsed.first { $0.text == "B" }?.style == ANSIArtStyle())
        #expect(parsed.first { $0.text == "C" }?.style.foreground == .indexed(1))
        #expect(parsed.first { $0.text == "D" }?.style == ANSIArtStyle())
    }

    @Test func stripsNonSGRSequencesWithoutLeakingTheirText() throws {
        let input = "\(esc)[?25l\(esc)[2J\(esc)[H\(esc)]0;window title\u{07}"
            + "\(esc)]8;;https://example.com\(esc)\\A\(esc)]8;;\(esc)\\"
            + "\(esc)(B\(esc)7B\(esc)[3CC\(esc)[>4;1mD\(esc)P+q544e\(esc)\\E\(esc)[?25h"
        let art = try #require(parser.parse(input))
        // `ESC[3C` moves over three blank cells rather than being dropped.
        #expect(art.lines.map(\.text) == ["AB   CDE"])
        // The private-marker `ESC[>4;1m` is not SGR and must not turn bold on.
        #expect(runs(art).allSatisfy { !$0.style.isBold })
    }

    @Test func unterminatedSequencesAreDroppedAndLaterLinesSurvive() throws {
        let art = try #require(parser.parse("A\(esc)[31\nB\(esc)]0;title\(esc)[32mC\(esc)"))
        #expect(art.lines.map(\.text) == ["A", "BC"])
        #expect(art.lines[1].runs.last?.style.foreground == .indexed(2))
    }

    @Test func controlCharactersAreDroppedAndTabsExpand() throws {
        let art = try #require(parser.parse("a\u{07}b\u{08}\r\n\tc\u{7F}\r\nab\td"))
        #expect(art.lines.map(\.text) == ["ab", "        c", "ab      d"])
    }

    @Test func trimsBlankEdgeLinesAndTrailingSpacesButKeepsColoredCells() throws {
        let art = try #require(parser.parse("\n   \n  x   \n\(esc)[41m  \(esc)[0m   \n\n"))
        #expect(art.lines.map(\.text) == ["  x", "  "])
        #expect(art.lines[1].runs.first?.style.background == .indexed(1))
        #expect(art.columnCount == 3)
    }

    @Test func emptyOrInvisibleInputHasNoArt() {
        #expect(parser.parse("") == nil)
        #expect(parser.parse(" \n\t\n\(esc)[31m\(esc)[0m\n") == nil)
    }

    @Test func rejectsInputOverTheByteCap() {
        let small = ANSIArtParser(maxBytes: 8)
        #expect(small.parse("12345678") != nil)
        #expect(small.parse("123456789") == nil)
        #expect(small.parse(data: Data(repeating: 0x41, count: 9)) == nil)
        #expect(ANSIArtParser.defaultMaxBytes == 64 * 1024)
    }

    @Test func capsLinesAndColumns() throws {
        let capped = ANSIArtParser(maxLines: 2, maxColumns: 3)
        let art = try #require(capped.parse("abcdef\n\(String(repeating: "x", count: 10))\nthird"))
        #expect(art.lines.map(\.text) == ["abc", "xxx"])
        #expect(art.columnCount == 3)
    }

    @Test func decodesInvalidUTF8Lossily() throws {
        let art = try #require(parser.parse(data: Data([0x41, 0xFF, 0x42])))
        #expect(art.lines.count == 1)
        #expect(art.lines[0].text.hasPrefix("A"))
        #expect(art.lines[0].text.hasSuffix("B"))
    }

    @Test func c1StringsAndMalformedCSIDoNotPrintTheirPayload() throws {
        let art = try #require(parser.parse("A\u{9D}0;title\u{07}B\u{90}payload\u{9C}C\(esc)[!1mD\(esc)[1 ;2mE"))
        #expect(art.lines.map(\.text) == ["ABCDE"])
        #expect(runs(art).allSatisfy { !$0.style.isBold })
    }

    @Test func colonTruecolorWithColorspaceAndExtrasPicksRGB() throws {
        let art = try #require(parser.parse("\(esc)[38:2:0:10:20:30:0:0mA\(esc)[48:2:1:40:50:60mB"))
        #expect(runs(art)[0].style.foreground == .rgb(ANSIArtRGB(10, 20, 30)))
        #expect(runs(art)[1].style.background == .rgb(ANSIArtRGB(40, 50, 60)))
    }

    @Test func wideCharactersTakeTwoCells() throws {
        let art = try #require(parser.parse("日本\u{1F600}a"))
        #expect(art.columnCount == 7)
        #expect(ANSIArt.cellWidth(of: "━") == 1)
        #expect(ANSIArt.cellWidth(of: "\u{AC00}") == 2)
    }

    @Test func combiningMarksShareTheirBaseCell() throws {
        let art = try #require(parser.parse("e\u{301}x\n\u{301}"))
        #expect(art.lines[0].columnCount == 2)
        #expect(ANSIArt.cellWidth(of: "\u{301}") == 0)
        #expect(ANSIArt.cellWidth(of: "A") == 1)
    }

    @Test func adjacentCellsWithTheSameStyleShareARun() throws {
        let art = try #require(parser.parse("\(esc)[31mab\(esc)[31mcd\(esc)[32me"))
        #expect(runs(art).map(\.text) == ["abcd", "e"])
    }

    @Test func cursorForwardLeavesBlankCellsInTheDefaultStyle() throws {
        let art = try #require(parser.parse("\(esc)[41mA\(esc)[3CB\(esc)[CC\(esc)[0CD\(esc)[?5CE"))
        #expect(art.lines.map(\.text) == ["A   B C DE"])
        #expect(runs(art).map(\.text) == ["A", "   ", "B", " ", "C", " ", "DE"])
        #expect(runs(art)[1].style == ANSIArtStyle())
        #expect(runs(art)[2].style.background == .indexed(1))
    }

    @Test func repeatRepeatsTheLastCharacterInTheCurrentStyle() throws {
        let art = try #require(parser.parse("\(esc)[31m\u{2580}\(esc)[4b\(esc)[32m\(esc)[b\nx\u{1F600}\(esc)[2b"))
        #expect(art.lines.map(\.text) == [String(repeating: "\u{2580}", count: 6), "x\u{1F600}\u{1F600}\u{1F600}"])
        #expect(runs(art).map(\.text) == [String(repeating: "\u{2580}", count: 5), "\u{2580}"])
        #expect(runs(art)[1].style.foreground == .indexed(2))
        #expect(art.lines[1].columnCount == 7)
    }

    @Test func cursorForwardAndRepeatStopAtTheColumnCap() throws {
        let capped = ANSIArtParser(maxColumns: 6)
        let art = try #require(capped.parse("ab\(esc)[999999999C\ncd\(esc)[999999999bx"))
        #expect(art.lines.map(\.text) == ["ab", "cddddd"])
    }

    @Test func controlsInsideASequenceAreSkippedWithoutEndingIt() throws {
        // DEL and CR inside a CSI are skipped (terminals ignore or execute
        // them); a newline ends the sequence and still breaks the line.
        let art = try #require(parser.parse("A\(esc)[3\u{7F}1mB\(esc)[1\r;32mC\(esc)[3\nD"))
        #expect(art.lines.map(\.text) == ["ABC", "D"])
        #expect(runs(art).first { $0.text == "B" }?.style.foreground == .indexed(1))
        #expect(runs(art).first { $0.text == "C" }?.style.isBold == true)
        #expect(runs(art).first { $0.text == "C" }?.style.foreground == .indexed(2))
    }

    @Test func emojiSequencesMeasureAsOneCellPair() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let heart = "\u{2764}\u{FE0F}"
        let flag = "\u{1F1E8}\u{1F1E6}"
        let art = try #require(parser.parse("\(family)\(heart)\(flag)\u{2764}a"))
        #expect(art.columnCount == 2 + 2 + 2 + 1 + 1)
        #expect(ANSIArt.cellWidth(of: Character(family)) == 2)
        #expect(ANSIArt.cellWidth(of: Character(heart)) == 2)
        #expect(ANSIArt.cellWidth(of: "\u{2764}") == 1)
        #expect(ANSIArt.cellWidth(of: "1\u{FE0F}\u{20E3}") == 2)
    }

    @Test func capsTheScalarsStackedOnOneCell() throws {
        let zalgo = "a" + String(repeating: "\u{301}", count: 5000) + "b"
        let art = try #require(parser.parse(zalgo))
        #expect(art.lines[0].text.unicodeScalars.count == ANSIArtBuilder.maxScalarsPerCell + 1)
        #expect(art.columnCount == 2)
    }

    @Test func longBlankLinesParseQuickly() throws {
        // A quadratic trailing-space trim made this take seconds.
        let line = String(repeating: " ", count: 399) + "x"
        let input = Array(repeating: line, count: 160).joined(separator: "\n")
        let art = parser.parse(input)
        #expect(art?.lines.count == 160)
        #expect(art?.columnCount == 400)
    }
}
