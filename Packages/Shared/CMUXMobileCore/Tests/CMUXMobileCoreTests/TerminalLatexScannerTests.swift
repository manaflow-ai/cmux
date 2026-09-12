import Testing
@testable import CMUXMobileCore

struct TerminalLatexScannerTests {
    private func scan(_ text: String, columns: Int = 100) throws -> [TerminalLatexEquation] {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal", stateSeq: 0, columns: columns,
            rows: text.split(separator: "\n", omittingEmptySubsequences: false).count, text: text
        )
        return TerminalLatexScanner().equations(in: frame)
    }

    @Test(arguments: ["$x^2$", #"\(x^2\)"#])
    func inline(_ math: String) throws {
        let equations = try scan("Answer: \(math) done")
        let equation = try #require(equations.first)
        #expect(equations.count == 1)
        #expect(equation.source == "x^2")
        #expect(!equation.display)
        #expect(equation.layout.column == 8)
        #expect(equation.layout.width == math.count)
        #expect(equation.layout.height == 1)
    }

    @Test(arguments: ["$$\n\\frac{a}{b}\n$$", "\\[\n\\frac{a}{b}\n\\]"])
    func block(_ math: String) throws {
        let equation = try #require(scan(math).first)
        #expect(equation.display)
        #expect(equation.source.contains(#"\frac{a}{b}"#))
        #expect(equation.regions.count == 3)
        #expect(equation.layout.height == 3)
    }

    @Test func streaming() throws {
        let text = #"Done $x^2$ then \(\frac{a}{b}\)"#
        for length in 0..<text.count {
            let equations = try scan(String(text.prefix(length)))
            #expect(equations.count == (length >= 10 ? 1 : 0))
        }
        #expect(try scan(text).count == 2)
        #expect(try scan("rewritten output").isEmpty)
    }

    @Test func literalCodeCurrencyAndUnclosedMath() throws {
        #expect(try scan(#"Pay $5 and $10; escaped \$x^2\$; `\(x\)`; $x"#).isEmpty)
        #expect(try scan("```latex\n$$x^2$$\n```\n$x$").map(\.source) == ["x"])
        #expect(try scan("```latex\n$$x^2$$\n````\n$y$").map(\.source) == ["y"])
        #expect(try scan("~~~\n$x$\n~~~").isEmpty)
        #expect(try scan("Price $12.50; result $x^2$.").map(\.source) == ["x^2"])
    }

    @Test func fullWidthWrapAndUnicodeCoordinates() throws {
        let equation = try #require(scan("$\\frac{a\n}{b}$", columns: 8).first)
        #expect(equation.source == #"\frac{a}{b}"#)
        #expect(equation.regions.count == 2)
        let unicode = try #require(scan("结果 $x$ é").first)
        #expect(unicode.layout.column == 5)
        #expect(unicode.layout.width == 3)
    }

    @Test func cursorAndConcealedTextStayRaw() throws {
        var frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal", stateSeq: 0, columns: 20, rows: 1, text: "$x$",
            cursor: .init(row: 0, column: 1)
        )
        #expect(TerminalLatexScanner().equations(in: frame).isEmpty)
        frame.cursor?.column = 10
        #expect(TerminalLatexScanner().equations(in: frame).isEmpty)
        frame.cursor = nil
        frame.styles = [.init(id: 0, invisible: true)]
        #expect(TerminalLatexScanner().equations(in: frame).isEmpty)
    }

    @Test func claudeAndCodexBulletIndentation() throws {
        for bullet in ["⏺", "•"] {
            let equation = try #require(scan("\(bullet) $$\n  \\frac{a}{b}\n  $$").first)
            #expect(equation.layout.column == 2)
            #expect(equation.layout.height == 3)
        }
        let prose = try #require(scan("Text $$\n  x\n$$").first)
        #expect(prose.layout.height == 1)
    }

    @Test func scrollAndStyleChangesUseCurrentCells() throws {
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal", stateSeq: 0, columns: 20, rows: 8,
            styles: [.init(id: 0, foreground: "#123456", background: "#abcdef")],
            rowSpans: [.init(row: 6, column: 3, text: "$x$", cellWidth: 3)]
        )
        #expect(TerminalLatexScanner().equations(in: frame).first?.layout.row == 6)
        frame.rowSpans[0].row = 2
        let equation = try #require(TerminalLatexScanner().equations(in: frame).first)
        #expect(equation.layout.row == 2)
        #expect(equation.foreground == "#123456")
        frame.rowSpans = []
        #expect(TerminalLatexScanner().equations(in: frame).isEmpty)
    }
}
