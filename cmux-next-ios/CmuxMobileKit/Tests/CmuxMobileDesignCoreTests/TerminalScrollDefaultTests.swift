import CmuxMobileDesignCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing

/// Leo, 2026-11-25: "Btw how do you feel about me making it just a normal iOS scroll instead of like by
/// line scroll in the terminal view?" (ask-f9e09f8eda) and "we can just treat the scroll like any
/// pedestrian scroll" (ask-9a05173841).
struct TerminalScrollDefaultTests {
    @Test func plainScrollIsTheDefault() {
        #expect(TerminalScrollDefault.plainScroll)
    }

    @Test func rubberBandShowsLessThanTheFingerMovedAndNeverPastTheScreen() {
        #expect(TerminalScrollMath.rubberBand(0, dimension: 600) == 0)
        #expect(TerminalScrollMath.rubberBand(-40, dimension: 600) == 0)
        #expect(TerminalScrollMath.rubberBand(100, dimension: 0) == 0)
        var last: CGFloat = 0
        for offset in stride(from: CGFloat(20), through: 20_000, by: 20) {
            let shown = TerminalScrollMath.rubberBand(offset, dimension: 600)
            #expect(shown > last && shown < offset && shown < 600)
            last = shown
        }
    }
}
