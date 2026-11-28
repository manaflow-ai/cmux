import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeRender

/// After a change settles, nothing stays armed: no deadline, no render job,
/// no ledger entries, no morph, no ghost (0% idle CPU; architecture.md section 5).
@MainActor
@Suite struct IdleTests {
    @Test func settlesToIdleAfterASendAndAReply() async throws {
        let deadline = ManualDeadline()
        let c = Fixtures.controller(height: 700, deadline: deadline)
        let messages = Fixtures.conversation(20)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        await c.scene.bitmaps.settled()
        #expect(c.isIdle, "an initial load does not animate")
        #expect(deadline.pending == nil)
        c.handle(.insertText("hello", replacing: nil))
        let intent = try #require(c.handle(.send))
        c.update(items: Fixtures.items(messages, pending: [PendingIntent(intent: intent)]), summary: Fixtures.summary(),
                 typing: [Fixtures.chief], hasOlder: false)
        c.update(items: Fixtures.items(messages + [Fixtures.message(21, Fixtures.chief, "Reply.")], pending: [PendingIntent(intent: intent)]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(!c.isIdle)
        let armed = try #require(deadline.pending, "a change arms exactly one cleanup deadline")
        #expect(armed.delay > .zero)
        // The deadline fires once per due time; each cleanup may arm the next one.
        var fires = 0
        while deadline.pending != nil, fires < 32 {
            deadline.fire()
            fires += 1
        }
        await c.scene.bitmaps.settled()
        #expect(deadline.pending == nil)
        #expect(c.isIdle)
        #expect(c.scene.ledger.isEmpty && c.scene.morphs.isEmpty && !c.scene.model.hasGhosts)
    }
}
