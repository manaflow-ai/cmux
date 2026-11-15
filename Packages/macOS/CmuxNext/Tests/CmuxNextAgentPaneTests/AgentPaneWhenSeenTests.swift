import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Lawrence's nightly ef384ddbc64d (2026-11-11, about 50 live agents): each turn's end computed its
/// repository's diff ahead of a diff tab (`DiffPageRuntime.warm`: a `git.status`, a full-patch
/// `git.diff` of 970 ms mean and 1.9 s at most, a sidecar child), for a chat nobody looked at too,
/// in front of the git reads of the view the person looked at. Work whose result only a person at
/// the chat uses is now owed to the chat's pane until someone can see it (``AgentPaneView/whenSeen``).
@Suite(.serialized)
@MainActor
struct AgentPaneWhenSeenTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func view(session: String? = nil) throws -> AgentPaneView {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost(), sessionId: session)
        return try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
    }

    /// A few turns of the main actor, for work owed to a later turn.
    private static func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aPaneNobodySeesRunsNoWorkUntilItShows() async throws {
        let view = try Self.view()
        var hidden = true
        view.shownPushes.isHidden = { _ in hidden }
        var ran: [String] = []

        // Three turns end while the chat is behind another tab.
        for turn in 1...3 { view.whenSeen("diffWarm") { ran.append("turn \(turn)") } }
        await Self.turns()
        #expect(ran.isEmpty, "a pane nobody sees ran \(ran)")

        // The person comes to the chat: one run, of the newest turn's work.
        hidden = false
        view.shownPushes.flush(view)
        #expect(ran == ["turn 3"])

        view.shownPushes.flush(view)
        #expect(ran == ["turn 3"], "the work ran again with nothing owed")
    }

    @Test func aPaneSomeoneSeesRunsTheWorkOnALaterTurn() async throws {
        let view = try Self.view()
        view.shownPushes.isHidden = { _ in false }
        var ran = 0

        view.whenSeen("diffWarm") { ran += 1 }
        #expect(ran == 0, "the work ran in the turn that asked")
        await Self.turns()
        #expect(ran == 1)
    }

    /// A session's work goes to the panes that show it, and runs once though two of them show.
    @Test func aSessionsWorkRunsOnceInThePanesThatShowIt() async throws {
        let views = try [Self.view(session: "chat-a"), Self.view(session: "chat-a"), Self.view(session: "chat-b")]
        for view in views { view.shownPushes.isHidden = { _ in false } }
        var ran = 0

        let owed = AgentPaneOwedWork()
        owed.owe(session: "chat-a", "diffWarm", in: views) { ran += 1 }
        await Self.turns()

        #expect(ran == 1)
        #expect(owed.owedSessions.isEmpty, "the work that ran is still owed")
        #expect(views[2].shownPushes.owedNames.isEmpty, "another chat's pane owes the work")
    }

    /// A chat nobody looks at often has no pane: its page was released to save memory, or no tab
    /// shows it yet. Its work is the chat's debt, and the pane made when the person comes takes it.
    @Test func aChatWithNoPaneOwesItsWorkToThePaneMadeLater() async throws {
        let owed = AgentPaneOwedWork()
        var ran: [String] = []

        // Two turns end while the chat has no pane.
        for turn in 1...2 { owed.owe(session: "chat-a", "diffWarm", in: [AgentPaneView]()) { ran.append("turn \(turn)") } }
        await Self.turns()
        #expect(ran.isEmpty, "a chat with no pane ran \(ran)")
        #expect(owed.owedSessions == ["chat-a"], "the chat owes one piece of work, the newest")

        // The person comes to the chat: the tab store makes its pane and hands it the debt.
        let views = try [Self.view(session: "chat-b"), Self.view(session: "chat-a")]
        for view in views { view.shownPushes.isHidden = { _ in false } }
        owed.hand(to: views)
        #expect(views[0].shownPushes.owedNames.isEmpty, "another chat's pane took the work")
        await Self.turns()
        #expect(ran == ["turn 2"])
        #expect(owed.owedSessions.isEmpty, "the work that ran is still owed")

        // A second pane of the chat finds nothing to run.
        let later = try Self.view(session: "chat-a")
        later.shownPushes.isHidden = { _ in false }
        owed.hand(to: [later])
        await Self.turns()
        #expect(ran == ["turn 2"], "the work ran again")
    }

    /// A pane can change its chat in place (the person starts a new chat on the same page, or the
    /// quick panel moves it): no pane is made, so the pane itself asks for the new chat's debt.
    @Test func aPaneThatChangesItsChatInPlaceTakesTheNewChatsDebt() async throws {
        let owed = AgentPaneOwedWork()
        var ran = 0
        owed.owe(session: "chat-b", "diffWarm", in: [AgentPaneView]()) { ran += 1 }

        // The tab store made a pane of another chat, and someone sees it.
        let view = try Self.view(session: "chat-a")
        view.shownPushes.isHidden = { _ in false }
        owed.hand(to: [view])
        await Self.turns()
        #expect(ran == 0, "a pane of another chat ran the work")

        // The page moves to the chat that owes the work.
        view.model.adoptSession("chat-b")
        await Self.turns()
        #expect(ran == 1, "the pane that came to the chat in place did not take its debt")
        #expect(owed.owedSessions.isEmpty)
    }

    /// A hidden pane holds its chat's work; when its page moves to another chat before anyone
    /// sees it, the work stays the first chat's and does not run for the chat the person sees.
    @Test func aHiddenPaneThatLeftItsChatLeavesThatChatsWorkOwed() async throws {
        let owed = AgentPaneOwedWork()
        let view = try Self.view(session: "chat-a")
        var hidden = true
        view.shownPushes.isHidden = { _ in hidden }
        var ran = 0
        owed.owe(session: "chat-a", "diffWarm", in: [view]) { ran += 1 }
        await Self.turns()

        // The page moves to another chat while it is hidden, then the person comes to it.
        view.model.adoptSession("chat-b")
        hidden = false
        view.shownPushes.flush(view)
        await Self.turns()
        #expect(ran == 0, "the work of the chat the pane left ran when the pane showed another chat")
        #expect(owed.owedSessions == ["chat-a"], "the chat the pane left lost its debt")

        // A pane of the first chat still takes it.
        let back = try Self.view(session: "chat-a")
        back.shownPushes.isHidden = { _ in false }
        owed.hand(to: [back])
        await Self.turns()
        #expect(ran == 1)
    }

    /// Chats that never get a pane again cannot grow the debts without end: the oldest go first.
    @Test func theDebtsOfChatsWithNoPaneAreBounded() {
        let owed = AgentPaneOwedWork()
        for chat in 0...AgentPaneOwedWork.limit { owed.owe(session: "chat-\(chat)", "diffWarm", in: [AgentPaneView]()) {} }
        #expect(owed.owedSessions.count == AgentPaneOwedWork.limit)
        #expect(owed.owedSessions.first == "chat-1", "the oldest debt was not the one dropped")
        #expect(owed.owedSessions.last == "chat-\(AgentPaneOwedWork.limit)")
    }
}
