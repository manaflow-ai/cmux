#if os(iOS)
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import SwiftUI
import Testing
@testable import CmuxMobileShell

/// Leo (2026-11-22): "why do things move when i scroll around and the momentum gets kept?
/// that shouldnt happen ... new updates even are a maybe." A terminal card's screen read
/// (the Mac's text, asked for when the card is built) that comes back while the grid scrolls
/// waits until the grid stops: the card keeps the picture it showed, and the new text lands
/// at rest.
@MainActor @Suite struct TerminalCardScrollHoldTests {
    @Test func aScreenReadLandingMidScrollWaitsForTheGridToStop() async throws {
        let source = GhosttyTerminalTabContent()
        source.frameStore = nil
        let store = AppStore.mock()
        let workspace = try #require(store.workspaces.first { $0.tabs.contains { $0.kind == .terminal } })
        let tab = try #require(workspace.tabs.first { $0.kind == .terminal })
        source.sessionProvider = { _, _ in nil }
        var answered = false
        source.screenTextProvider = { _, _ in
            answered = true
            return "$ ls\nREADME.md"
        }
        source.overviewScrollingChanged(true)
        source.prepareCard(for: tab, in: workspace)
        let model = try #require(source.model(forTabID: tab.id))
        for _ in 0 ..< 200 where !answered { await Task.yield() }
        #expect(answered, "the card asked the Mac for its screen")
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(model.cardScreenText == nil, "the card's text changed while the grid scrolled")
        source.overviewScrollingChanged(false)
        #expect(model.cardScreenText == "$ ls\nREADME.md", "the held text lands once the grid stops")
        source.reset()
    }

    /// The grid can hide while it still moves (a card tapped mid-fling): no stop is
    /// reported after that, so the held text lands when the grid hides.
    @Test func aGridThatHidesMidScrollStillGetsTheHeldText() async throws {
        let source = GhosttyTerminalTabContent()
        source.frameStore = nil
        let store = AppStore.mock()
        let workspace = try #require(store.workspaces.first { $0.tabs.contains { $0.kind == .terminal } })
        let tab = try #require(workspace.tabs.first { $0.kind == .terminal })
        source.sessionProvider = { _, _ in nil }
        var answered = false
        source.screenTextProvider = { _, _ in
            answered = true
            return "$ ls\nREADME.md"
        }
        source.overviewVisibilityChanged(true) { [] }
        source.overviewScrollingChanged(true)
        source.prepareCard(for: tab, in: workspace)
        let model = try #require(source.model(forTabID: tab.id))
        for _ in 0 ..< 200 where !answered { await Task.yield() }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(model.cardScreenText == nil, "the card's text changed while the grid scrolled")
        source.overviewVisibilityChanged(false) { [] }
        #expect(model.cardScreenText == "$ ls\nREADME.md", "the held text lands when the grid hides")
        source.reset()
    }
}
#endif
