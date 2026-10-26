import AppKit
@testable import CmuxNextTabs
import Testing

/// A target strip opens an optimistic gap before the daemon accepts a tab move.
/// A rejected move must close that committed gap immediately; otherwise the
/// target keeps a phantom slot and the drag ghost appears stuck in the strip.
@MainActor
struct TabDropRollbackTests {
    @Test func aRejectedDropDoesNotKeepTheCommittedPhantom() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("target"), title: "Target")], selectedID: TabID("target"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()

        let point = strip.convert(CGPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let target = try #require(strip.updatePhantom(atScreenPoint: point))
        strip.commitPhantom(tabID: TabID("dragged"))
        #expect(strip.pendingDrop?.id == TabID("dragged"))
        #expect(strip.dropPlaceholderIndex == target.index)

        // The daemon rejected the move: its model still contains only the
        // original tab. The owning pane's forced resync rolls back the
        // optimistic gap before it applies that model.
        strip.discardPendingDrop()
        #expect(strip.pendingDrop == nil)
        #expect(strip.dropPlaceholderIndex == nil)
        #expect(strip.dropPlaceholderGroup == nil)
        #expect(strip.displayedOrder == [TabID("target")])
    }
}
