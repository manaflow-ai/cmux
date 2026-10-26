import CoreGraphics
import CoreText
import Testing
@testable import CmuxHomeRender

/// The body and file chip fonts are made once and held in ``SharedFont``s
/// (p10-stability-054, they were `nonisolated(unsafe) static let`s). The
/// measure and row bitmap queues read them from many threads at once: every
/// read is the one held instance, and every thread measures what the main
/// actor measures. Run under TSan as well (`swift test --sanitize=thread`).
@Suite struct SharedFontTests {
    static let sample = "Look at this, a long enough line to measure 12345"

    @Test func everyReadIsTheOneHeldFont() {
        #expect(Style.bodyFont === Style.bodyFont)
        #expect(FileChip.nameFont === FileChip.nameFont)
        #expect(FileChip.detailFont === FileChip.detailFont)
        #expect(FileChip.badgeFont === FileChip.badgeFont)
        #expect(CTFontGetSize(Style.bodyFont) == Style.bodySize)
        #expect(CTFontGetSize(FileChip.nameFont) == 13)
        #expect(CTFontGetSize(FileChip.detailFont) == 11)
        #expect(CTFontGetSize(FileChip.badgeFont) == 7)
    }

    @Test func threadsMeasureWithTheSharedFontsAtOnce() async {
        let expected = Self.widths()
        let measured = await withTaskGroup(of: [CGFloat].self) { group in
            for _ in 0..<64 {
                group.addTask { Self.widths() }
            }
            var all: [[CGFloat]] = []
            for await widths in group { all.append(widths) }
            return all
        }
        #expect(measured.count == 64)
        #expect(measured.allSatisfy { $0 == expected })
    }

    private static func widths() -> [CGFloat] {
        [Style.bodyFont, FileChip.nameFont, FileChip.detailFont, FileChip.badgeFont].map {
            TextDraw.width(sample, font: $0, kern: Style.bodyKern)
        }
    }
}
