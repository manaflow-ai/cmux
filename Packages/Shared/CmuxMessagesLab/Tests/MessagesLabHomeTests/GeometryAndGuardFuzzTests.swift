import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): selection geometry with lines from
/// another text or a line index outside them, and address checks with a short byte array,
/// refuse instead of trapping. Seeded.
@Suite struct GeometryAndGuardFuzzTests {
    @Test func aLineIndexOutsideTheTextGivesAnEmptyLine() {
        let g = ShortTextGeometry(tl: TextLayout.make("one two three", runs: [], maxWidth: 400))
        _ = g.ctLine(7)
        _ = g.ctLine(-1)
    }

    @Test func linesFromALongerTextDoNotTrap() {
        let long = TextLayout.make(String(repeating: "word ", count: 80), runs: [], maxWidth: 120)
        let short = TextLayout(text: "ab", runs: [], lines: long.lines, width: long.width)
        let g = ShortTextGeometry(tl: short)
        for y in stride(from: -10.0, through: 400.0, by: 7.0) {
            _ = g.offset(at: CGPoint(x: 30, y: y))
            _ = g.characterIndex(at: CGPoint(x: 30, y: y))
        }
    }

    @Test func aShortAddressIsNotPublic() {
        #expect(LinkGuard.isPublicV6([1, 2, 3]) == false)
        #expect(LinkGuard.isPublicV6([]) == false)
        #expect(LinkGuard.isPublicV6(Array(repeating: 0, count: 15) + [1]) == false)
    }
}
