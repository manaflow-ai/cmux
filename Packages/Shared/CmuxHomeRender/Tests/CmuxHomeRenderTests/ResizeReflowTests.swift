import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct ResizeReflowTests {
    private func specs(_ c: HomeController) -> [String: RowSpec] {
        Dictionary(c.scene.model.rows.map { ($0.spec.key, $0.spec) }, uniquingKeysWith: { a, _ in a })
    }

    /// A width change re-measures only parts whose wrap can change and
    /// redraws only rows whose content changed; every other row keeps its
    /// spec and its bitmap (the prototype redrew every row on every step).
    @Test(arguments: [560.0, 700.0, 1000.0])
    func reflowTouchesOnlyChangedRows(width: Double) {
        let c = Fixtures.controller(width: 628, height: 1041)
        let messages = Fixtures.conversation(40)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let before = specs(c)
        let visibleBefore = Set(c.scene.visible.keys)
        let measures = c.builder.measure.measureCount
        let renders = c.scene.bitmaps.renderCount

        c.resize(to: CGSize(width: width, height: 1041))

        let after = specs(c)
        #expect(Set(after.keys) == Set(before.keys))
        let changed = Set(after.keys.filter { after[$0] != before[$0] })
        let longParts = Set(messages.filter { $0.plainText == Fixtures.longLine }.map { "part:\($0.clientMessageID.rawValue):0" })
        #expect(changed.isSubset(of: longParts), "only wrapped text reflows: \(changed.subtracting(longParts))")
        #expect(c.builder.measure.measureCount - measures == longParts.count)
        let visibleAfter = Set(c.scene.visible.keys)
        let mayDraw = visibleAfter.intersection(changed).union(visibleAfter.subtracting(visibleBefore))
        #expect(c.scene.bitmaps.renderCount - renders <= mayDraw.count)
        #expect(c.isPinnedToNewest)
    }

    /// Short rows keep their bitmaps across many live-resize steps.
    @Test func liveResizeOfShortRowsDrawsNothing() {
        let c = Fixtures.controller(width: 628, height: 900)
        let short = (1...30).map { Fixtures.message(Seq($0), $0 % 3 == 0 ? Fixtures.me : Fixtures.chief, "Short line \($0)") }
        c.update(items: Fixtures.items(short), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let measures = c.builder.measure.measureCount
        let renders = c.scene.bitmaps.renderCount
        for step in 1...40 { c.resize(to: CGSize(width: 628 + CGFloat(step) * 3, height: 900)) }
        #expect(c.builder.measure.measureCount == measures)
        #expect(c.scene.bitmaps.renderCount == renders)
    }

    /// A height-only resize keeps the rows; a scrolled viewport keeps its first row.
    @Test func heightResizeKeepsTheReadingPosition() throws {
        let c = Fixtures.controller(width: 628, height: 800)
        c.update(items: Fixtures.items(Fixtures.conversation(80)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        c.handle(.scroll(deltaY: 600, phase: .changed, momentum: .none))
        let anchor = try #require(c.scene.visibleAnchor())
        let renders = c.scene.bitmaps.renderCount
        c.resize(to: CGSize(width: 628, height: 700))
        let i = try #require(c.scene.model.index[anchor.key])
        #expect(abs(c.scene.windowY(contentY: c.scene.layout.contentTop(i)) - anchor.y) < 0.01)
        #expect(c.scene.bitmaps.renderCount == renders)
    }

    @Test func narrowerWrapIsRemeasuredWiderSingleLineIsNot() {
        let tl = TextLayout.make("A short line", maxWidth: 358.4, font: Style.bodyFont)
        #expect(tl.isValid(atMaxWidth: 300, measuredAt: 358.4))
        #expect(!tl.isValid(atMaxWidth: tl.width - 1, measuredAt: 358.4))
        let wrapped = TextLayout.make(Fixtures.longLine, maxWidth: 358.4, font: Style.bodyFont)
        #expect(!wrapped.isValid(atMaxWidth: 400, measuredAt: 358.4))
        #expect(wrapped.isValid(atMaxWidth: 358.4, measuredAt: 358.4))
    }
}
