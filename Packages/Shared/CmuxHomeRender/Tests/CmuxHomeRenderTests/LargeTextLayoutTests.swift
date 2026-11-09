import CmuxHomeCore
import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// At the largest accessibility text sizes (iOS AX5: textScale about 4.08 on a
/// 402 pt iPhone) every bubble stays inside the viewport: the gutters stop
/// growing with the text, the text column fits what is left, and a word
/// longer than the column breaks (homerender-ios-host.md item 8).
@MainActor
@Suite struct LargeTextLayoutTests {
    @Test(arguments: [1.31, 2.0, 3.0, 4.08])
    func everyBubbleStaysInsideTheViewport(textScale: Double) async throws {
        let width: CGFloat = 402
        let c = Fixtures.controller(width: width, height: 874)
        let them = Fixtures.chief
        let messages = [
            Fixtures.message(1, them, "The backend. deploy finished; supercalifragilisticexpialidocious"),
            Fixtures.message(2, Fixtures.me, "Thanks, ship it to staging please"),
            Fixtures.message(3, them, "backend."),
        ]
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        c.textScale = CGFloat(textScale)
        await c.bitmapsSettled()
        let bubbles = c.hits(in: CGRect(x: 0, y: 0, width: width, height: 874)).map(\.bubble)
        #expect(!bubbles.isEmpty)
        for bubble in bubbles {
            #expect(bubble.minX >= 0 && bubble.maxX <= width, "bubble \(bubble) leaves the \(width) pt viewport at \(textScale)x")
        }
    }

    @Test func theReferenceLayoutIsUnchanged() {
        let m = Metrics(width: Style.referenceWidth, zoom: 1)
        #expect(m.leftEdge == Style.leftEdge)
        #expect(m.rightEdge == Style.referenceWidth - Style.rightInset)
        #expect(m.maxTextWidth == Style.maxTextWidth)
    }
}
