import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Host API for the UIKit and AppKit hosts (cli-requests/homerender-ios-host.md).
@MainActor
@Suite struct HostAPITests {
    @Test func contentsScaleRedrawsRowsAtTheNewScale() async {
        let c = Fixtures.controller(height: 700)
        c.update(items: Fixtures.items(Fixtures.conversation(8)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.bitmapsSettled()
        let before = c.scene.bitmaps.renderCount
        c.contentsScale = 3
        await c.bitmapsSettled()
        #expect(c.scene.bitmaps.renderCount > before, "rows are redrawn at 3x")
        let scales = c.scene.visible.values.map(\.bitmap.contentsScale)
        #expect(scales.allSatisfy { $0 == 3 })
    }

    @Test func contentFrameFindsALoadedMessage() throws {
        let c = Fixtures.controller(height: 700)
        let messages = Fixtures.conversation(30)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let first = try #require(c.contentFrame(for: messages[0].clientMessageID))
        let last = try #require(c.contentFrame(for: messages[29].clientMessageID))
        #expect(first.minY < last.minY)
        #expect(c.contentFrame(for: IdempotencyKey("missing")) == nil)
    }

    @Test func aRefusedHostedSendGoesBackToTheHost() throws {
        let c = Fixtures.controller(height: 700)
        c.setHostedField(CGRect(x: 16, y: 650, width: 596, height: 30))
        var restored: [String] = []
        c.onRestoreDraft = { restored.append($0) }
        let intent = try #require(c.sendHosted(text: "Retry me", from: .zero))
        c.restoreDraft(for: intent.key)
        #expect(restored == ["Retry me"])
    }

    @Test func messageItemsCarryTheirItemKey() {
        let c = Fixtures.controller(height: 700)
        let messages = Fixtures.conversation(4)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let keys = Set(c.accessibilityItems().compactMap(\.item))
        #expect(keys == Set(messages.map(\.clientMessageID)))
    }

    @Test func rowsChangeOnlyWhenRowsDo() {
        let c = Fixtures.controller(height: 700)
        var rows = 0
        c.onRowsChange = { rows += 1 }
        c.update(items: Fixtures.items(Fixtures.conversation(40)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(rows == 1)
        c.handle(.scroll(deltaY: 100, phase: .changed, momentum: .none))
        #expect(rows == 1, "scrolling is not a rows change")
    }

    @Test func fieldKeyframesRunFromOldToNew() throws {
        let c = Fixtures.controller(height: 700)
        let old = CGRect(x: 16, y: 600, width: 596, height: 79)
        let new = CGRect(x: 16, y: 649, width: 596, height: 30)
        let k = try #require(c.fieldKeyframes(from: old, to: new, send: true))
        #expect(k.frames.first == old)
        #expect(k.frames.last == new)
        #expect(k.keyTimes.count == k.frames.count)
    }
}
