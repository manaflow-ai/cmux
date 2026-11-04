@testable import CmuxNextBrowser
import CmuxNextInput
import Foundation
import Testing

/// Every cmux page tab gets a Chromium pane of its own (`cmux-page-<UUID>`), so each page builds its own
/// window, in the pages profile. This is the shipped default (the `pageTabsShareChromiumWindow` feature
/// off) and pins it for that feature's removal (prove-or-remove 11-04, row p13-20).
@MainActor @Suite struct CEFPageTabOwnWindowTests {
    @Test func eachPageTabHasAPaneOfItsOwn() {
        let engine = CEFEngine(layout: nil, stores: BrowserSharedStores.inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())
        let first = engine.pagesTabConfiguration(chatOpen: nil)
        let second = engine.pagesTabConfiguration(chatOpen: nil)
        let panes = [first.pane?.rawValue ?? "", second.pane?.rawValue ?? ""]
        #expect(panes[0] != panes[1], "two page tabs share one Chromium pane")
        #expect(panes.allSatisfy { $0.hasPrefix("cmux-page-") && !$0.hasPrefix("cmux-page-pane-") }, "\(panes)")
        #expect(first.profile == engine.beginPagesProfile() && second.profile == first.profile)
    }
}
