@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentPane
@testable import CmuxNextComputerUse
import Foundation
import Testing

/// The live preview card (B6): which chat shows a Computer Use session, and the card's states,
/// fed with fake helper sessions and events.
struct ComputerUsePreviewBoardTests {
    // MARK: Fixtures

    static func session(_ id: String, live: Bool = true, at seconds: Double = 100, kind: String = "claude",
                        acp: String? = nil, harness: String? = nil, workspace: String? = nil,
                        app: String = "Calculator", acts: Int = 1) -> ComputerUsePreviewSession {
        ComputerUsePreviewSession(id: id, live: live, app: app, bundleID: "com.apple.calculator", agentKind: kind,
                                  acpSession: acp, harnessSessionID: harness, workspaceID: workspace,
                                  lastActionAt: Date(timeIntervalSince1970: seconds), steps: acts)
    }

    static func chat(_ key: String, session: String? = nil, agent: String? = nil, workspace: String? = nil,
                     harness: String? = "claude", working: Bool = false, turnEnded: Bool = false) -> ComputerUsePreviewChat {
        ComputerUsePreviewChat(key: key, session: session ?? "acp-\(key)", agentSession: agent, workspaceID: workspace,
                               harness: harness, working: working, turnEnded: turnEnded)
    }

    /// A frame's capture time, `seconds` after 1970.
    static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// A legacy helper event, with its after frame.
    static func event(_ seq: UInt64, frame blob: String?, expired: Bool = false) -> AgentActivityEvent {
        AgentActivityEvent(seq: seq, time: Date(timeIntervalSince1970: Double(seq)), kind: .act, tool: "click",
                           afterFrame: blob.map { AgentActivityFrameRef(blob: $0, width: 320, height: 200, expired: expired) })
    }

    /// A board with session `s` running in chat `a`, its frame `b1` loaded.
    static func running() -> ComputerUsePreviewBoard {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [session("s")])
        board.route(chats: [chat("a", working: true), chat("b")])
        board.apply(newestFrame: "b1", at: Self.at(1), session: "s")
        board.loaded(.init(id: "b1", at: Self.at(1), url: "data:image/jpeg;base64,AA=="), session: "s")
        return board
    }

    // MARK: Mapping a session to its chat

    @Test func anAcpSessionIdNamesTheChat() {
        let chats = [Self.chat("a", working: true), Self.chat("b", session: "acp-9")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", acp: "acp-9"), chats: chats)
        #expect(pick == .init(key: "b", exact: true))
    }

    @Test func aHarnessSessionIdNamesTheChat() {
        let chats = [Self.chat("a", working: true), Self.chat("b", agent: "claude-1")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", harness: "claude-1"), chats: chats)
        #expect(pick == .init(key: "b", exact: true))
    }

    @Test func anExactAcpSessionMustBelongToTheReportedWorkspace() {
        let wrong = Self.chat("wrong", session: "acp-target", workspace: "w-other")
        let session = Self.session("s", acp: "acp-target", workspace: "w-owner")
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: [wrong]) == nil)
        let owner = Self.chat("owner", session: "acp-target", workspace: "w-owner")
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: [wrong, owner]) == .init(key: "owner", exact: true))
    }

    @Test func anAmbiguousAcpSessionMustNotFallThroughToItsHarness() {
        let chats = [Self.chat("a", session: "acp-shared", agent: "h", workspace: "w"),
                     Self.chat("b", session: "acp-shared", agent: "h", workspace: "w")]
        let session = Self.session("s", acp: "acp-shared", harness: "h", workspace: "w")
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: chats) == nil)
    }

    @Test func aHarnessIdMustAgreeWithWorkspaceAndFamily() {
        let session = Self.session("s", kind: "claude", harness: "shared", workspace: "w-owner")
        let elsewhere = Self.chat("elsewhere", agent: "shared", workspace: "w-other")
        let otherFamily = Self.chat("other-family", agent: "shared", workspace: "w-owner", harness: "codex")
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: [elsewhere]) == nil)
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: [otherFamily]) == nil)
        let owner = Self.chat("owner", agent: "shared", workspace: "w-owner", harness: "claude")
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: [elsewhere, otherFamily, owner]) == .init(key: "owner", exact: true))
    }

    @Test func duplicateHarnessIdsNeverPickTheFirstChat() {
        let session = Self.session("s", harness: "shared", workspace: "w")
        let chats = [Self.chat("a", agent: "shared", workspace: "w"),
                     Self.chat("b", agent: "shared", workspace: "w")]
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: chats) == nil)
        #expect(ComputerUsePreviewRoute.pick(for: session, chats: Array(chats.reversed())) == nil)
    }

    @Test func anotherWorkspacesLiveComputerFrameCannotAppearInThisChat() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("s", harness: "shared", workspace: "w-owner")])
        board.route(chats: [Self.chat("other", agent: "shared", workspace: "w-other", working: true)])
        board.apply(newestFrame: "frame", at: Self.at(1), session: "s")
        board.loaded(.init(id: "frame", at: Self.at(1), url: "data:image/jpeg;base64,AA=="), session: "s")
        #expect(board.card(for: "other") == nil)
    }

    @Test func theWorkingChatOfTheWorkspaceWins() {
        let chats = [Self.chat("a", workspace: "w1", working: true), Self.chat("b", workspace: "w2", working: true),
                     Self.chat("c", workspace: "w2")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", workspace: "w2"), chats: chats)
        #expect(pick == .init(key: "b", exact: false))
    }

    @Test func withNoIdsTheOneWorkingChatOfTheSameFamilyWins() {
        let chats = [Self.chat("codex", harness: "codex", working: true), Self.chat("claude", working: true), Self.chat("idle")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", kind: "claude"), chats: chats)
        #expect(pick == .init(key: "claude", exact: false))
    }

    @Test func severalWorkingChatsShowNoCard() {
        let chats = [Self.chat("a", working: true), Self.chat("b", working: true), Self.chat("c")]
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: chats) == nil)
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: []) == nil)
    }

    @Test func anIdThatNamesNoOpenChatShowsNoCard() {
        let chats = [Self.chat("a", working: true)]
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s", acp: "acp-gone"), chats: chats) == nil)
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s", harness: "h-gone"), chats: chats) == nil)
    }

    @Test func noFittingChatShowsNoCard() {
        let idle = [Self.chat("a"), Self.chat("b")]
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: idle) == nil)
    }

    @Test func aSessionThatNamesItsWorkspaceShowsOnlyThere() {
        let chats = [Self.chat("a", workspace: "w2", working: true)]
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s", workspace: "w1"), chats: chats) == nil)
    }

    @Test func anUnknownAgentGoesOnlyToTheOneChatThatWorks() {
        let unknown = Self.session("s", kind: "unknown")
        let one = [Self.chat("a", working: true), Self.chat("b", harness: "codex")]
        #expect(ComputerUsePreviewRoute.pick(for: unknown, chats: one) == .init(key: "a", exact: false))
        let two = [Self.chat("a", working: true), Self.chat("b", harness: "codex", working: true)]
        #expect(ComputerUsePreviewRoute.pick(for: unknown, chats: two) == nil)
        // Its workspace does not narrow two working chats to one, nor give it the workspace's idle chat.
        let inW1 = Self.session("s", kind: "unknown", workspace: "w1")
        let both = [Self.chat("a", workspace: "w1", working: true), Self.chat("b", workspace: "w2", working: true)]
        #expect(ComputerUsePreviewRoute.pick(for: inW1, chats: both) == nil)
        let idleHere = [Self.chat("a", workspace: "w1"), Self.chat("b", workspace: "w2", working: true)]
        #expect(ComputerUsePreviewRoute.pick(for: inW1, chats: idleHere) == nil)
    }

    @Test func agentKindsMapToFamilies() {
        #expect(ComputerUsePreviewRoute.family("claude") == "claude")
        #expect(ComputerUsePreviewRoute.family("acp:codex") == "codex")
        #expect(ComputerUsePreviewRoute.family("Claude-Code") == "claude")
        #expect(ComputerUsePreviewRoute.family("unknown") == nil)
        #expect(ComputerUsePreviewRoute.family(nil) == nil)
    }

    @Test func aGuessedChatStaysButAnIdMovesIt() {
        var board = Self.running()
        // Another chat starts working: the card does not jump there.
        board.route(chats: [Self.chat("a"), Self.chat("b", working: true)])
        #expect(board.card(for: "a") != nil)
        #expect(board.card(for: "b") == nil)
        // The helper later names the chat: the card moves to it.
        var named = Self.session("s", acp: "acp-b")
        named.lastActionAt = Date(timeIntervalSince1970: 101)
        board.apply(sessions: [named])
        board.route(chats: [Self.chat("a"), Self.chat("b")])
        #expect(board.card(for: "a") == nil)
        #expect(board.card(for: "b")?.session == "s")
    }

    @Test func aRunningSessionWhoseChatClosedMovesToAnotherChat() {
        var board = Self.running()
        board.route(chats: [Self.chat("b", working: true)])
        #expect(board.card(for: "b")?.session == "s")
    }

    @Test func aTabThatSwitchesChatDropsTheOldChatsCard() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("s", acp: "acp-A")])
        board.route(chats: [Self.chat("t", session: "acp-A")])
        board.apply(newestFrame: "b1", at: Self.at(1), session: "s")
        board.loaded(.init(id: "b1", at: Self.at(1), url: "data:image/jpeg;base64,AA=="), session: "s")
        #expect(board.card(for: "t")?.session == "s")
        // `chat.select`: tab t now shows chat B, under the same key.
        board.route(chats: [Self.chat("t", session: "acp-B", working: true)])
        #expect(board.card(for: "t") == nil, "chat A's session does not show in chat B")
        #expect(board.nextLoad() == nil)
        // Back to chat A: its card comes back.
        board.route(chats: [Self.chat("t", session: "acp-A")])
        #expect(board.card(for: "t")?.session == "s")
    }

    @Test func aGuessedRouteIsDroppedWhenItsTabSwitchesChat() {
        var board = Self.running()
        board.route(chats: [Self.chat("a", session: "acp-other"), Self.chat("b")])
        #expect(board.card(for: "a") == nil)
        #expect(board.card(for: "b") == nil)
    }

    @Test func anEndedSessionWhoseTabSwitchedChatShowsNowhere() {
        var board = Self.running()
        board.apply(sessions: [Self.session("s", live: false)])
        board.route(chats: [Self.chat("a", session: "acp-other", working: true)])
        #expect(board.card(for: "a") == nil)
    }

    // MARK: Card states

    @Test func aRunningSessionShowsItsNewestFrameOnceLoaded() {
        var board = ComputerUsePreviewBoard()
        #expect(board.apply(sessions: [Self.session("s")]) == ["s"])
        board.route(chats: [Self.chat("a", working: true)])
        #expect(board.card(for: "a") == nil, "no card before a frame")
        board.apply(newestFrame: "b3", at: Self.at(3), session: "s")
        #expect(board.nextLoad()?.frame.id == "b3")
        board.loaded(.init(id: "b3", at: Self.at(3), url: "data:image/jpeg;base64,AA=="), session: "s")
        #expect(board.nextLoad() == nil)
        let apps = [ComputerUsePreviewApp.Key(bundleID: "com.apple.calculator", pid: nil):
            ComputerUsePreviewApp(name: "Calculator", icon: "data:image/png;base64,AA==")]
        let card = board.card(for: "a", apps: apps)
        #expect(card == ComputerUsePreviewCard(session: "s", app: "Calculator", done: false,
                                               frame: "data:image/jpeg;base64,AA=="), "running: no icon is sent")
    }

    @Test func anEndedSessionKeepsItsLastFrameAndTurnsDone() {
        var board = Self.running()
        let read = board.apply(sessions: [Self.session("s", live: false)])
        #expect(read == ["s"], "its last events are read once more")
        #expect(board.followed.isEmpty)
        let card = board.card(for: "a")
        #expect(card?.done == true)
        #expect(card?.frame == "data:image/jpeg;base64,AA==")
    }

    /// The card draws the agent's cursor at its last click: only while it runs, and only in the
    /// window its frames show (a click in another window would land on the wrong spot).
    @Test func aRunningCardCarriesTheLastClickInItsWindow() {
        var board = Self.running()
        let calculator = ComputerUsePreviewWindow(pid: 40846, windowID: 7)
        board.apply(window: calculator, session: "s")
        let click = ComputerUsePreviewPointer(window: calculator, x: 0.25, y: 0.75, click: 3)
        board.apply(pointer: click, session: "s")
        #expect(board.card(for: "a")?.pointer == click)
        board.apply(window: ComputerUsePreviewWindow(pid: 40846, windowID: 8), session: "s")
        #expect(board.card(for: "a")?.pointer == nil, "the click was in another window")
        board.apply(window: calculator, session: "s")
        board.apply(sessions: [Self.session("s", live: false)])
        #expect(board.card(for: "a")?.done == true)
        #expect(board.card(for: "a")?.pointer == nil, "a done card draws no cursor")
    }

    /// Agents click by accessibility element, which reports no point: the live agent cursor gives the
    /// position, and any click event plays the click (seen 2026-10-28: every Calculator click was an
    /// `element_index` click with no `click_point`).
    @Test func theLiveCursorWinsAndAnAccessibilityClickPlays() {
        var board = Self.running()
        let calculator = ComputerUsePreviewWindow(pid: 40846, windowID: 7)
        board.apply(window: calculator, session: "s")
        board.apply(click: 9, session: "s")
        #expect(board.card(for: "a")?.pointer == nil, "no position yet")
        board.apply(cursor: ComputerUseAgentCursor(point: CGPoint(x: 0.4, y: 0.6), windowWidth: 230), session: "s")
        #expect(board.card(for: "a")?.pointer == ComputerUsePreviewPointer(window: calculator, x: 0.4, y: 0.6, click: 9, windowWidth: 230))
        board.apply(pointer: ComputerUsePreviewPointer(window: calculator, x: 0.1, y: 0.1, click: 4), session: "s")
        #expect(board.card(for: "a")?.pointer?.x == 0.4, "the live cursor wins over an older pixel click")
        board.apply(cursor: nil, session: "s")
        #expect(board.card(for: "a")?.pointer == ComputerUsePreviewPointer(window: calculator, x: 0.1, y: 0.1, click: 9))
    }

    @Test func theCursorWindowsCenterIsAFractionOfTheTargetWindow() {
        let window = CGRect(x: 100, y: 200, width: 400, height: 300)
        let inside = CGPoint(x: 200, y: 350), outside = CGPoint(x: 50, y: 50)
        #expect(ComputerUseAgentCursorWindows.fraction([outside, inside], in: window) == CGPoint(x: 0.25, y: 0.5))
        #expect(ComputerUseAgentCursorWindows.fraction([outside], in: window) == nil)
        #expect(ComputerUseAgentCursorWindows.fraction([inside], in: nil) == nil)
    }

    @Test func onlyClickToolsPlayTheClick() {
        func act(_ tool: String) -> AgentActivityEvent { AgentActivityEvent(seq: 1, time: Self.at(1), kind: .act, tool: tool) }
        #expect(ComputerUseActivityPreviewSource.isClick(act("click")))
        #expect(ComputerUseActivityPreviewSource.isClick(act("double_click")))
        #expect(!ComputerUseActivityPreviewSource.isClick(act("type_text")))
        #expect(!ComputerUseActivityPreviewSource.isClick(AgentActivityEvent(seq: 1, time: Self.at(1), kind: .observe, tool: "click")))
    }

    /// The source takes a batch's newest click that names its window, and keeps the point inside it.
    @Test func theSourceTakesTheNewestClickWithItsWindow() {
        let window = AgentActivityTargetWindow(pid: 1, windowID: 2)
        func click(_ seq: UInt64, x: Double, window: AgentActivityTargetWindow?) -> AgentActivityEvent {
            AgentActivityEvent(seq: seq, time: Self.at(Double(seq)), kind: .act, tool: "click",
                               clickPoint: CGPoint(x: x, y: 0.5), window: window)
        }
        let events = [click(1, x: 0.1, window: window), click(2, x: 1.4, window: window), click(3, x: 0.3, window: nil),
                      Self.event(4, frame: "b4")]
        let pointer = ComputerUseActivityPreviewSource.pointer(events)
        #expect(pointer == ComputerUsePreviewPointer(window: window, x: 1, y: 0.5, click: 2))
        #expect(ComputerUseActivityPreviewSource.pointer([Self.event(1, frame: "b1")]) == nil)
    }

    @Test func aCardTurnsDoneWhenItsChatsTurnEndsAndRunsAgainWithTheNextAct() {
        var board = Self.running()
        board.route(chats: [Self.chat("a", turnEnded: true), Self.chat("b")])
        #expect(board.card(for: "a")?.done == true, "the turn that used the app is over")
        #expect(board.followed.isEmpty)
        // The next turn acts again: the card runs again in the same chat.
        #expect(board.apply(sessions: [Self.session("s", at: 101, acts: 2)]) == ["s"])
        board.route(chats: [Self.chat("a", working: true), Self.chat("b")])
        #expect(board.card(for: "a")?.done == false)
    }

    @Test func anIdleChatThatNeverWorkedDoesNotEndTheCard() {
        var board = ComputerUsePreviewBoard()
        // An id routes the session to an idle chat: an agent outside the chat's turns.
        board.apply(sessions: [Self.session("s", acp: "acp-a")])
        board.route(chats: [Self.chat("a", turnEnded: true)])
        board.apply(newestFrame: "b1", at: Self.at(1), session: "s")
        board.loaded(.init(id: "b1", at: Self.at(1), url: "data:image/jpeg;base64,AA=="), session: "s")
        #expect(board.card(for: "a")?.done == false)
    }

    @Test func chatsReadTheirSessionsLane() {
        let lane = AgentActivityLane(id: "acp-1", name: "calc", title: "calc", peer: nil, parent: nil, state: .working, since: nil,
                                     error: nil, workspaceID: "w-1", harness: "claude", chat: "claude-code:abc")
        let chats = ComputerUsePreviewChat.chats(keys: ["tab-b", "tab-a"], session: { $0 == "tab-a" ? "acp-1" : nil },
                                                 lanes: ["acp-1": lane])
        #expect(chats == [
            ComputerUsePreviewChat(key: "tab-a", session: "acp-1", agentSession: "abc", workspaceID: "w-1", harness: "claude",
                                   working: true, turnEnded: false),
            ComputerUsePreviewChat(key: "tab-b", session: nil),
        ])
    }

    @Test func laneStatesThatEndATurn() {
        #expect(ComputerUsePreviewChat.turnEnded(.idle))
        #expect(ComputerUsePreviewChat.turnEnded(.failed))
        #expect(ComputerUsePreviewChat.turnEnded(.lost))
        #expect(!ComputerUsePreviewChat.turnEnded(.working))
        #expect(!ComputerUsePreviewChat.turnEnded(.input))
        #expect(!ComputerUsePreviewChat.turnEnded(nil))
    }

    @Test func aSessionGoneFromTheListTurnsDone() {
        var board = Self.running()
        board.apply(sessions: [])
        #expect(board.card(for: "a")?.done == true)
    }

    @Test func aSessionFirstSeenEndedNeverShows() {
        var board = ComputerUsePreviewBoard()
        #expect(board.apply(sessions: [Self.session("old", live: false)]).isEmpty)
        #expect(board.entries.isEmpty)
    }

    @Test func closeHidesTheCardForThatSessionOnly() {
        var board = Self.running()
        board.dismiss(session: "s")
        #expect(board.card(for: "a") == nil)
        #expect(board.followed.isEmpty)
        // New frames of the closed session load nothing.
        board.apply(newestFrame: "b2", at: Self.at(2), session: "s")
        #expect(board.nextLoad() == nil)
        // A newer session in the same chat shows its own card.
        board.apply(sessions: [Self.session("s"), Self.session("t", at: 200)])
        board.route(chats: [Self.chat("a", working: true)])
        board.apply(newestFrame: "t1", at: Self.at(1), session: "t")
        board.loaded(.init(id: "t1", at: Self.at(1), url: "data:image/png;base64,AA=="), session: "t")
        #expect(board.card(for: "a")?.session == "t")
    }

    @Test func settingOffHidesEveryCardAndKeepsNothing() {
        var board = Self.running()
        board.enabled = false
        #expect(board.card(for: "a") == nil)
        #expect(board.entries.isEmpty)
        #expect(board.apply(sessions: [Self.session("s")]).isEmpty)
        board.enabled = true
        #expect(board.apply(sessions: [Self.session("s")]) == ["s"])
    }

    @Test func aCardIsLiveWhileAnyOfItsChatsSessionsIs() {
        var board = Self.running()
        board.apply(sessions: [Self.session("s", at: 100), Self.session("t", at: 300)])
        board.route(chats: [Self.chat("a", working: true)])
        board.apply(newestFrame: "t5", at: Self.at(5), session: "t")
        board.loaded(.init(id: "t5", at: Self.at(5), url: "data:image/png;base64,AA=="), session: "t")
        board.apply(sessions: [Self.session("s", at: 100), Self.session("t", live: false, at: 300)])
        let card = board.card(for: "a")
        #expect(card?.session == "t", "the newest frame shows, though its session ended")
        #expect(card?.done == false, "s still runs")
        board.apply(sessions: [Self.session("s", live: false, at: 100), Self.session("t", live: false, at: 300)])
        #expect(board.card(for: "a")?.done == true)
    }

    @Test func sessionsOfOneChatFeedOneCardInCaptureOrder() {
        // One agent turn made two sessions at once: one launched the app and observed, the other clicked.
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("click", at: 100), Self.session("launch", at: 101)])
        board.route(chats: [Self.chat("a", working: true)])
        /// Names `frame` of `session`, loads what the board asks for next, and gives chat a's card.
        func step(_ frame: String, of session: String, at seconds: Double) -> ComputerUsePreviewCard? {
            board.apply(newestFrame: frame, at: Self.at(seconds), session: session)
            if let next = board.nextLoad() {
                board.loaded(.init(id: next.frame.id, at: next.frame.at, url: "data:image/png;base64,\(next.frame.id)"),
                             session: next.session)
            }
            return board.card(for: "a")
        }
        #expect(step("l1", of: "launch", at: 6.5)?.frame == "data:image/png;base64,l1")
        #expect(step("c1", of: "click", at: 13.7)?.frame == "data:image/png;base64,c1")
        #expect(step("c8", of: "click", at: 28.3)?.frame == "data:image/png;base64,c8")
        let last = step("l2", of: "launch", at: 38.5)
        #expect(last?.frame == "data:image/png;base64,l2")
        #expect(last?.session == "launch")
        // A frame captured before the shown one, named late, neither loads nor shows.
        #expect(step("c9", of: "click", at: 30)?.frame == "data:image/png;base64,l2")
        #expect(board.nextLoad() == nil)
        // Live while either session is; done once both ended.
        board.apply(sessions: [Self.session("click", at: 100), Self.session("launch", live: false, at: 101)])
        #expect(board.card(for: "a")?.done == false)
        board.apply(sessions: [Self.session("click", live: false, at: 100), Self.session("launch", live: false, at: 101)])
        #expect(board.card(for: "a")?.done == true)
    }

    @Test func closeHidesTheChatsCardForAllItsSessions() {
        var board = Self.running()
        board.apply(sessions: [Self.session("s"), Self.session("t", at: 200)])
        board.route(chats: [Self.chat("a", working: true)])
        board.apply(newestFrame: "t2", at: Self.at(2), session: "t")
        board.loaded(.init(id: "t2", at: Self.at(2), url: "data:image/png;base64,AA=="), session: "t")
        board.dismiss(session: "t")
        #expect(board.card(for: "a") == nil)
        #expect(board.followed.isEmpty)
    }

    @Test func theNewestFrameLoadsFirst() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("old", at: 100), Self.session("new", at: 200)])
        board.route(chats: [Self.chat("a", working: true)])
        board.apply(newestFrame: "o1", at: Self.at(1), session: "old")
        board.apply(newestFrame: "n1", at: Self.at(2), session: "new")
        #expect(board.nextLoad()?.session == "new")
    }

    @Test func aSessionThatActedIsReadAgainAndAQuietOneIsNot() {
        var board = Self.running()
        #expect(board.apply(sessions: [Self.session("s")]).isEmpty)
        #expect(board.apply(sessions: [Self.session("s", at: 101, acts: 2)]) == ["s"])
    }

    @Test func theBoardKeepsABoundedNumberOfSessions() {
        var board = ComputerUsePreviewBoard()
        let sessions = (0..<20).map { Self.session("s\($0)", at: Double($0)) }
        board.apply(sessions: sessions)
        #expect(board.entries.count == ComputerUsePreviewBoard.maximumEntries)
        #expect(board.entries["s19"] != nil)
        #expect(board.entries["s0"] == nil)
    }

    @Test func aFrameThatFailsIsNotAskedForAgainAndTheCardKeepsItsFrame() {
        var board = Self.running()
        board.apply(newestFrame: "b2", at: Self.at(2), session: "s")
        #expect(board.nextLoad()?.frame.id == "b2")
        board.failed("b2", session: "s")
        #expect(board.nextLoad() == nil)
        #expect(board.card(for: "a")?.frame == "data:image/jpeg;base64,AA==")
    }

    // MARK: The legacy helper source

    @Test func theLegacySourceNamesTheNewestFrameWithPixels() {
        let events = [Self.event(1, frame: "b1"), Self.event(2, frame: nil), Self.event(3, frame: "b3"),
                      Self.event(4, frame: "b4", expired: true)]
        #expect(ComputerUseActivityPreviewSource.newestFrame(events)?.id == "b3")
        #expect(ComputerUseActivityPreviewSource.newestFrame(events)?.at == Self.at(3), "captured with its event")
        #expect(ComputerUseActivityPreviewSource.newestFrame([Self.event(1, frame: nil)]) == nil)
    }

    @Test func theLegacySourceMapsAHelperSession() {
        let record = AgentActivitySession(
            id: "cua_1", machine: "local", machineName: "This Mac", label: "calc", agentKind: "codex", agentName: "Codex",
            attribution: .none, colorHex: "#888888", targetApps: ["Notes", "Calculator"], status: .ended(.agentEnd),
            startedAt: Date(timeIntervalSince1970: 1), lastActionAt: Date(timeIntervalSince1970: 5), acts: 2, observes: 3,
            acpSession: "acp-1", workspaceID: "w-1", targetApp: "Calculator", targetBundleID: "com.apple.calculator",
            targetPID: 40846, targetWindowTitle: "Calculator")
        let session = ComputerUseActivityPreviewSource.session(record)
        #expect(session == ComputerUsePreviewSession(id: "cua_1", live: false, app: "Calculator", bundleID: "com.apple.calculator",
                                                     pid: 40846, windowTitle: "Calculator",
                                                     agentKind: "codex", acpSession: "acp-1", workspaceID: "w-1",
                                                     lastActionAt: Date(timeIntervalSince1970: 5), steps: 5))
    }

    // MARK: Wire and page request

    @Test func theWireReadsWhatLinksASessionToItsChat() throws {
        let json: [String: Any] = [
            "id": "cua_native_1", "label": "calc",
            "agent": ["kind": "claude", "acp_session": "acp-1", "harness_session_id": "h-1", "workspace_id": "w-1"],
            "targets": [["app_name": "Notes", "app_bundle_id": "com.apple.Notes"],
                        ["app_name": "Calculator", "app_bundle_id": "com.apple.calculator"]],
            "status": ["state": "active"],
        ]
        let session = try #require(AgentActivityWire.session(json, machine: "local", machineName: "This Mac"))
        #expect(session.acpSession == "acp-1")
        #expect(session.harnessSessionID == "h-1")
        #expect(session.workspaceID == "w-1")
        #expect(session.targetApp == "Calculator")
        #expect(session.targetBundleID == "com.apple.calculator")
    }

    @Test func thePageAsksToOpenOrCloseTheCard() {
        #expect(AgentPaneRequest(body: ["method": "chat.computerUsePreview", "params": ["action": "open"]]) == .computerUsePreview(.open))
        #expect(AgentPaneRequest(body: ["method": "chat.computerUsePreview", "params": ["action": "close"]]) == .computerUsePreview(.close))
        #expect(AgentPaneRequest(body: ["method": "chat.computerUsePreview", "params": ["action": "stop"]])
            == .unsupported("chat.computerUsePreview"))
        #expect(AgentPaneRequest(body: ["method": "chat.computerUsePreview", "params": ["action": "open", "session": "x"]])
            == .unsupported("chat.computerUsePreview"))
    }
}
