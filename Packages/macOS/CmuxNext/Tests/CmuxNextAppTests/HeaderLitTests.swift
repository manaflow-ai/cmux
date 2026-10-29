import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWakeups
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
                                         push: { pushed.append($0) }, on: Self.work())
        #expect(watch.read().lit == ["splitBrowserRight"])
        // The user closes the browser from its own tab, not from the header.
        let browser = row.tab(.browser)
        _ = row.registry.perform("closeTab", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .tab, id: browser), origin: .user))
        await drainMainTurns()
        #expect(pushed.map(\.lit) == [[]])
    }

    /// The header watch is one FrameObservation: the changes of one turn reach the page as one push,
    /// with no `Task` per change.
    @Test func theChangesOfOneTurnArePushedOnce() async {
        let row = Row(), toggles = AgentChatSplitToggles()
        var pushed: [AgentPaneHeaderState] = []
        let watch = AgentChatHeaderWatch(state: { toggles.headerState(chat: row.chat, store: row.store) },
                                         push: { pushed.append($0) }, on: Self.work())
        #expect(watch.read().lit == [])
        row.click("splitRight", toggles: toggles)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(pushed.isEmpty, "a change pushed inside its will-set")
        await drainMainTurns()
        #expect(pushed.map(\.lit) == [["splitBrowserRight", "splitRight"]], "\(pushed.count) pushes for one turn's changes (want 1)")
        await drainMainTurns()
        #expect(pushed.count == 1, "a push with nothing changed")
    }

    /// A main-thread scheduler with no display link: a visible post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }
}

extension HeaderSplitOrderTests.Row {
    /// The id of the row's tab of `kind`.
    func tab(_ kind: TabKind) -> String {
        Self.id(panes.first { $0.kind == kind }?.surface ?? 0)
    }
}
