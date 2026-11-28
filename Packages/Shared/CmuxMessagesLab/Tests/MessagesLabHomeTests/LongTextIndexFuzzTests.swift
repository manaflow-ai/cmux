import AppKit
import Testing
@testable import MessagesLabHome

/// Crash program (index_subscript / int_conversion): a block index or a point from an
/// older layout of a long text (streaming replaces the index while tiles and selection
/// still hold the old one) refuses or clamps instead of trapping. Seeded.
@MainActor @Suite struct LongTextIndexFuzzTests {
    static func text(_ seed: UInt64, paragraphs: Int) -> String {
        var s = seed
        func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: (s >> 33) % UInt64(max(1, n))) }
        let words = ["alpha", "beta", "日本語", "👩‍👩‍👧‍👦", "e\u{301}", "word", String(repeating: "x", count: 900), "\t"]
        return (0..<paragraphs).map { _ in (0..<(1 + next(60))).map { _ in words[next(words.count)] }.joined(separator: " ") }.joined(separator: "\n")
    }

    @Test func aFenwickTreeIgnoresAStaleIndex() {
        var f = Fenwick([1, 2, 3])
        f.set(7, 5)
        f.set(-1, 5)
        #expect(f.total == 6)
        #expect(f.prefix(99) == 6)
        #expect(f.find(Int.max) == 2)
    }

    @Test func aBlockIndexFromALongerTextReadsNothing() {
        let index = LongTextIndex.build(Self.text(1, paragraphs: 40), lineage: 9001)
        let layout = LongTextLayout(index: index, width: 600)
        let stale = index.blockCount + 5
        #expect(layout.lines(ofBlock: stale) == 0)
        #expect(layout.isExact(stale) == false)
        #expect(layout.isExact(-1) == false)
        _ = layout.key(stale)
        #expect(index.blockString(stale).length == 0)
        _ = index.u16Offset(utf8: index.count + 50)
        layout.report(stale, 3)
        _ = layout.applyPending()
        layout.require(blocks: stale..<(stale + 2))
    }

    @Test func nonFinitePointsAndRangesDoNotTrap() {
        let index = LongTextIndex.build(Self.text(2, paragraphs: 30), lineage: 9002)
        let layout = LongTextLayout(index: index, width: 500)
        layout.measureNow(0..<index.blockCount)
        for y in [CGFloat.nan, .infinity, -.infinity, 1e300, -1e300] {
            _ = layout.anchor(atTextY: y)
            _ = layout.offset(at: CGPoint(x: 10, y: y))
        }
        for v in [CGFloat(0)...CGFloat.infinity, -CGFloat.infinity...0, CGFloat(0)...1e300] {
            _ = layout.rects(for: NSRange(location: 0, length: 400), visible: v)
        }
        _ = layout.substring(NSRange(location: 0, length: Int.max / 2))
    }

    @Test func randomTextsLayoutsAndQueriesDoNotTrap() {
        for seed in UInt64(1)...40 {
            let text = Self.text(seed, paragraphs: Int(seed % 50) + 1)
            let index = LongTextIndex.build(text, lineage: 9100 + Int(seed))
            let width = CGFloat(120 + Int(seed) * 37 % 700)
            let layout = LongTextLayout(index: index, width: width, provisional: seed % 3 == 0 ? Int(seed) % 7 - 2 : nil)
            layout.measureNow(0..<index.blockCount)
            let total = layout.totalLines
            for line in [-3, 0, total / 2, total, total + 9] {
                _ = layout.block(containingLine: line)
                _ = layout.offset(at: CGPoint(x: 40, y: CGFloat(line) * 16))
            }
            _ = layout.rects(for: NSRange(location: 3, length: 200), visible: 0...CGFloat(total * 16))
        }
    }
}
