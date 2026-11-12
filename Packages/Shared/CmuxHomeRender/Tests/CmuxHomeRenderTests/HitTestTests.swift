import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct HitTestTests {
    @Test func aPointInABubbleFindsItsMessageAndAGapFindsNothing() throws {
        let c = Fixtures.controller(width: 628, height: 900)
        let messages = Fixtures.conversation(12)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let all = c.hits(in: CGRect(x: 0, y: 0, width: 628, height: 900))
        #expect(!all.isEmpty)
        let last = try #require(all.last)
        #expect(last.text == messages.last?.plainText)
        let found = try #require(c.hit(at: CGPoint(x: last.bubble.midX, y: last.bubble.midY)))
        #expect(found == last)
        #expect(c.hit(at: CGPoint(x: 2, y: last.bubble.midY)) == nil, "the left margin is not a bubble")
        let tops = all.map(\.bubble.minY)
        #expect(tops == tops.sorted(), "hits come top to bottom")
    }
}
