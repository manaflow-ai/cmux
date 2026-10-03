import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeRender

/// After a change settles, nothing stays armed: no wake task, no ledger
/// entries, no morph, no ghost (0% idle CPU; architecture.md section 5).
@MainActor
@Suite struct IdleTests {
    @Test func settlesToIdleAfterASendAndAReply() async throws {
        let c = Fixtures.controller(height: 700)
        let messages = Fixtures.conversation(20)
        c.update(items: Fixtures.items(messages), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.isIdle, "an initial load does not animate")
        c.handle(.insertText("hello", replacing: nil))
        let intent = try #require(c.handle(.send))
        c.update(items: Fixtures.items(messages, pending: [PendingIntent(intent: intent)]), summary: Fixtures.summary(),
                 typing: [Fixtures.chief], hasOlder: false)
        c.update(items: Fixtures.items(messages + [Fixtures.message(21, Fixtures.chief, "Reply.")], pending: [PendingIntent(intent: intent)]),
                 summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(!c.isIdle)
        // Real time: the cleanup wakes run on the controller's clock.
        try await Task.sleep(for: .milliseconds(2500))
        #expect(c.isIdle)
        #expect(c.scene.ledger.isEmpty && c.scene.morphs.isEmpty && !c.scene.model.hasGhosts)
    }
}
