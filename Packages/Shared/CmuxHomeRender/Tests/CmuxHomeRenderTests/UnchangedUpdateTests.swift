import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeRender

/// `HomeStoreBinding` refreshes on every inbox change, so an update that
/// carries the same transcript, summary, typing and paging state must not
/// lay out, animate or call back.
@MainActor
@Suite struct UnchangedUpdateTests {
    @Test func anUnchangedUpdateDoesNoLayoutPass() {
        let c = Fixtures.controller(height: 900)
        let items = Fixtures.items(Fixtures.conversation(200))
        c.update(items: items, summary: Fixtures.summary(), typing: [], hasOlder: true)
        let passes = c.scene.commitCount
        var callbacks = 0
        c.onScrollGeometryChange = { _ in callbacks += 1 }
        c.onAccessibilityChange = { callbacks += 1 }
        c.onSummaryChange = { _ in callbacks += 1 }
        for _ in 0..<50 {
            c.update(items: items, summary: Fixtures.summary(), typing: [], hasOlder: true)
        }
        #expect(c.scene.commitCount == passes, "no layout pass for an unchanged transcript")
        #expect(callbacks == 0)
        c.update(items: Fixtures.items(Fixtures.conversation(201)), summary: Fixtures.summary(), typing: [], hasOlder: true)
        #expect(c.scene.commitCount == passes + 1, "a real change lays out once")
    }
}
