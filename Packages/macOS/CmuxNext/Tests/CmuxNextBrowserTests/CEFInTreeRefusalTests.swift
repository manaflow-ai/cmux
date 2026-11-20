import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// In-tree hosting (fork API 36) of a page the fork refuses, without Chromium: a fake fork call and a run-loop turn the
/// test ends itself. A refused page retries once, then goes back to layer hosting (`fallBack`), so it never shows blank.
/// The retry used to wait for the next show of the page, which a host Chromium never shows again (a docked DevTools'
/// own host view) never got: DevTools stayed blank in tree, never falling back (live step 0c505ae5 on cmux19).
@MainActor
@Suite(.serialized) struct CEFInTreeRefusalTests {
    /// Blocks waiting for the end of the run-loop turn.
    final class Turn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        var isEmpty: Bool { blocks.isEmpty }
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    /// The fork side: refuses every request, or takes it from the `takeFrom`-th call on.
    final class FakeFork {
        var takeFrom = Int.max
        private(set) var requests = 0
        let page = NSView()
        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in
                guard container != nil else { return nil }
                requests += 1
                return requests >= takeFrom ? page : nil
            }, contentView: { _ in nil })
        }
    }

    private func withInTreeOn(_ body: () throws -> Void) rethrows {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        try body()
    }

    @Test func aRefusedPageNoShowEverComesToFallsBackAfterTheNextTurn() {
        withInTreeOn {
            let turn = Turn()
            let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let hosting = CEFInTreeHosting(schedule: { turn.add($0) })
            hosting.view = host
            var fellBack = 0
            hosting.fallBack = { fellBack += 1 }
            let fork = FakeFork()

            #expect(hosting.pageWindowCreated(browser: 9, calls: fork.calls))
            turn.end()  // the creation stack returned: the first request, refused
            #expect(fork.requests == 1)
            #expect(fellBack == 0)
            // No show of this page ever comes (a docked DevTools' host). The next turn's retry, refused again, hands
            // the page back to layer hosting.
            turn.end()
            #expect(fork.requests == 2, "a refused page waited for a show that never comes")
            #expect(fellBack == 1, "a page refused twice did not go back to layer hosting: it shows blank")
            #expect(hosting.fellBack)
            #expect(!hosting.isInTree)
        }
    }

    @Test func aRefusedPageTakenOnTheRetryIsInTreeAndRetriesOnce() {
        withInTreeOn {
            let turn = Turn()
            let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let hosting = CEFInTreeHosting(schedule: { turn.add($0) })
            hosting.view = host
            var fellBack = 0
            hosting.fallBack = { fellBack += 1 }
            let fork = FakeFork()
            fork.takeFrom = 2

            #expect(hosting.pageWindowCreated(browser: 9, calls: fork.calls))
            turn.end()
            turn.end()
            #expect(hosting.isInTree)
            #expect(fellBack == 0)
            // A show after the page came into the tree asks nothing more.
            hosting.pageShown(browser: 9)
            turn.end()
            #expect(fork.requests == 2)
        }
    }

    @Test func aShowBeforeTheTurnEndsTakesTheOneRetry() {
        withInTreeOn {
            let turn = Turn()
            let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let hosting = CEFInTreeHosting(schedule: { turn.add($0) })
            hosting.view = host
            var fellBack = 0
            hosting.fallBack = { fellBack += 1 }
            let fork = FakeFork()

            #expect(hosting.pageWindowCreated(browser: 9, calls: fork.calls))
            turn.end()
            hosting.pageShown(browser: 9)  // the show retries first: refused again, back to layer hosting
            #expect(fork.requests == 2)
            #expect(fellBack == 1)
            turn.end()  // the turn's retry finds nothing armed
            #expect(fork.requests == 2, "the page asked a third time")
            #expect(fellBack == 1)
        }
    }

    /// A page Chromium makes itself (a docked DevTools, a window.open popup) stays on layer hosting: the fork attaches
    /// such a page in tree but it draws nothing (live step ff7bb179 on cmux19, devtools.pixels 2 colours and
    /// popup.pixels blank in tree, 80 colours off). Its host never asks the fork.
    @Test func aPageNotAllowedInTreeNeverAsksTheFork() {
        withInTreeOn {
            let turn = Turn()
            let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let hosting = CEFInTreeHosting(schedule: { turn.add($0) })
            hosting.view = host
            hosting.isAllowed = false
            let fork = FakeFork()
            fork.takeFrom = 1

            #expect(!hosting.pageWindowCreated(browser: 9, calls: fork.calls), "a DevTools or popup page went in tree")
            turn.end()
            turn.end()
            #expect(fork.requests == 0)
            #expect(!hosting.isInTree)
        }
    }
}
