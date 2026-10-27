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

    /// A legacy helper event, with its after frame.
    static func event(_ seq: UInt64, frame blob: String?, expired: Bool = false) -> AgentActivityEvent {
        AgentActivityEvent(seq: seq, time: Date(timeIntervalSince1970: Double(seq)), kind: .act, tool: "click",
                           afterFrame: blob.map { AgentActivityFrameRef(blob: $0, width: 320, height: 200, expired: expired) })
    }

    /// A board with session `s` running in chat `a`, its frame `b1` loaded.
    static func running() -> ComputerUsePreviewBoard {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [session("s")])
        board.route(chats: [chat("a", working: true), chat("b")], focused: "b")
        board.apply(newestFrame: "b1", session: "s")
        board.loaded(.init(id: "b1", url: "data:image/jpeg;base64,AA=="), session: "s")
        return board
    }

    // MARK: Mapping a session to its chat

    @Test func anAcpSessionIdNamesTheChat() {
        let chats = [Self.chat("a", working: true), Self.chat("b", session: "acp-9")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", acp: "acp-9"), chats: chats, focused: "a")
        #expect(pick == .init(key: "b", exact: true))
    }

    @Test func aHarnessSessionIdNamesTheChat() {
        let chats = [Self.chat("a", working: true), Self.chat("b", agent: "claude-1")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", harness: "claude-1"), chats: chats, focused: "a")
        #expect(pick == .init(key: "b", exact: true))
    }

    @Test func theWorkingChatOfTheWorkspaceWins() {
        let chats = [Self.chat("a", workspace: "w1", working: true), Self.chat("b", workspace: "w2", working: true),
                     Self.chat("c", workspace: "w2")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", workspace: "w2"), chats: chats, focused: "a")
        #expect(pick == .init(key: "b", exact: false))
    }

    @Test func withNoIdsTheOneWorkingChatOfTheSameFamilyWins() {
        let chats = [Self.chat("codex", harness: "codex", working: true), Self.chat("claude", working: true), Self.chat("idle")]
        let pick = ComputerUsePreviewRoute.pick(for: Self.session("s", kind: "claude"), chats: chats, focused: "idle")
        #expect(pick == .init(key: "claude", exact: false))
    }

    @Test func severalWorkingChatsFallBackToTheFocusedChat() {
        let chats = [Self.chat("a", working: true), Self.chat("b", working: true), Self.chat("c")]
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: chats, focused: "c") == .init(key: "c", exact: false))
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: chats, focused: nil) == nil)
        #expect(ComputerUsePreviewRoute.pick(for: Self.session("s"), chats: [], focused: "c") == nil)
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
        board.route(chats: [Self.chat("a"), Self.chat("b", working: true)], focused: "b")
        #expect(board.card(for: "a") != nil)
        #expect(board.card(for: "b") == nil)
        // The helper later names the chat: the card moves to it.
        var named = Self.session("s", acp: "acp-b")
        named.lastActionAt = Date(timeIntervalSince1970: 101)
        board.apply(sessions: [named])
        board.route(chats: [Self.chat("a"), Self.chat("b")], focused: "a")
        #expect(board.card(for: "a") == nil)
        #expect(board.card(for: "b")?.session == "s")
    }

    @Test func aRunningSessionWhoseChatClosedMovesToAnotherChat() {
        var board = Self.running()
        board.route(chats: [Self.chat("b")], focused: "b")
        #expect(board.card(for: "b")?.session == "s")
    }

    // MARK: Card states

    @Test func aRunningSessionShowsItsNewestFrameOnceLoaded() {
        var board = ComputerUsePreviewBoard()
        #expect(board.apply(sessions: [Self.session("s")]) == ["s"])
        board.route(chats: [Self.chat("a", working: true)], focused: nil)
        #expect(board.card(for: "a") == nil, "no card before a frame")
        board.apply(newestFrame: "b3", session: "s")
        #expect(board.nextLoad()?.frame == "b3")
        board.loaded(.init(id: "b3", url: "data:image/jpeg;base64,AA=="), session: "s")
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

    @Test func aCardTurnsDoneWhenItsChatsTurnEndsAndRunsAgainWithTheNextAct() {
        var board = Self.running()
        board.route(chats: [Self.chat("a", turnEnded: true), Self.chat("b")], focused: "b")
        #expect(board.card(for: "a")?.done == true, "the turn that used the app is over")
        #expect(board.followed.isEmpty)
        // The next turn acts again: the card runs again in the same chat.
        #expect(board.apply(sessions: [Self.session("s", at: 101, acts: 2)]) == ["s"])
        board.route(chats: [Self.chat("a", working: true), Self.chat("b")], focused: "b")
        #expect(board.card(for: "a")?.done == false)
    }

    @Test func anIdleChatThatNeverWorkedDoesNotEndTheCard() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("s")])
        // An agent outside any chat's turn lands in the focused chat, which is idle.
        board.route(chats: [Self.chat("a", turnEnded: true)], focused: "a")
        board.apply(newestFrame: "b1", session: "s")
        board.loaded(.init(id: "b1", url: "data:image/jpeg;base64,AA=="), session: "s")
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
        board.apply(newestFrame: "b2", session: "s")
        #expect(board.nextLoad() == nil)
        // A newer session in the same chat shows its own card.
        board.apply(sessions: [Self.session("s"), Self.session("t", at: 200)])
        board.route(chats: [Self.chat("a", working: true)], focused: "a")
        board.apply(newestFrame: "t1", session: "t")
        board.loaded(.init(id: "t1", url: "data:image/png;base64,AA=="), session: "t")
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

    @Test func aRunningSessionWinsOverANewerEndedOne() {
        var board = Self.running()
        board.apply(sessions: [Self.session("s", at: 100), Self.session("t", at: 300)])
        board.route(chats: [Self.chat("a", working: true)], focused: "a")
        board.apply(newestFrame: "t1", session: "t")
        board.loaded(.init(id: "t1", url: "data:image/png;base64,AA=="), session: "t")
        board.apply(sessions: [Self.session("s", at: 100), Self.session("t", live: false, at: 300)])
        #expect(board.card(for: "a")?.session == "s")
    }

    @Test func theNewestSessionsFrameLoadsFirst() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [Self.session("old", at: 100), Self.session("new", at: 200)])
        board.route(chats: [Self.chat("a", working: true)], focused: "a")
        board.apply(newestFrame: "o1", session: "old")
        board.apply(newestFrame: "n1", session: "new")
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
        board.apply(newestFrame: "b2", session: "s")
        #expect(board.nextLoad()?.frame == "b2")
        board.failed("b2", session: "s")
        #expect(board.nextLoad() == nil)
        #expect(board.card(for: "a")?.frame == "data:image/jpeg;base64,AA==")
    }

    // MARK: The legacy helper source

    @Test func theLegacySourceNamesTheNewestFrameWithPixels() {
        let events = [Self.event(1, frame: "b1"), Self.event(2, frame: nil), Self.event(3, frame: "b3"),
                      Self.event(4, frame: "b4", expired: true)]
        #expect(ComputerUseActivityPreviewSource.newestFrame(events) == "b3")
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
