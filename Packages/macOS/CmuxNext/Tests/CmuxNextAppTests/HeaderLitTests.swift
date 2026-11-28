import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's toggle buttons light while the panel they opened is open (cx-00n1, Claude Code
/// desktop's top right): Terminal and Browser report on from their own split, off once it closes,
/// whether the header closed it or the user closed it elsewhere, and the page hears that at once.
@MainActor
struct HeaderLitTests {
    typealias Row = HeaderSplitOrderTests.Row

    @Test func aToggleIsOnWhileTheSplitItOpenedIsOpen() {
        let row = Row(), toggles = AgentChatSplitToggles()
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == [])
        row.click("splitRight", toggles: toggles)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight", "splitRight"])
        row.click("splitRight", toggles: toggles)
        #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight"])
    }

    @Test func closingTheSplitFromItsOwnTabTellsThePageItIsOff() async {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitBrowserRight", toggles: toggles)
        var pushed: [AgentPaneHeaderState] = []
        let watch = AgentChatHeaderWatch(state: { toggles.headerState(chat: row.chat, store: row.store) },
                                         push: { pushed.append($0) })
        #expect(watch.read().lit == ["splitBrowserRight"])
        // The user closes the browser from its own tab, not from the header.
        let browser = row.tab(.browser)
        _ = row.registry.perform("closeTab", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .tab, id: browser), origin: .user))
        for _ in 0..<20 where pushed.isEmpty { await Task.yield() }
        #expect(pushed.map(\.lit) == [[]])
    }
}

extension HeaderSplitOrderTests.Row {
    /// The id of the row's tab of `kind`.
    func tab(_ kind: TabKind) -> String {
        Self.id(panes.first { $0.kind == kind }?.surface ?? 0)
    }
}
