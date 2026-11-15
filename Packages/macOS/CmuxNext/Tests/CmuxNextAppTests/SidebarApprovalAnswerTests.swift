import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextDaemon
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// cmuxterm-hq#7794 ("the #1 dealbreaker"): the sidebar's Needs You tray and the Priority rows could
/// not Allow or Deny a pending tool permission, so the person had to open the chat. Now a waiting chat
/// of this Mac whose one pending prompt is a tool permission gets Allow and Deny on its row, and y and
/// n while the row has the focus. The App only wires: it reads and answers through the approval
/// banners' answerer, unchanged.
@MainActor @Suite(.serialized) struct SidebarApprovalAnswerTests {
    /// Stands in for this Mac's acpmux: one pending prompt per session, and the answers it got.
    final class Answerer: AgentApprovalAnswering {
        var pending: [String: AgentApproval] = [:]
        var accepts = true
        var lookups: [String] = []
        var answered: [(approval: AgentApproval, allow: Bool)] = []

        func pendingApproval(session: String) async -> AgentApproval? {
            lookups.append(session)
            return pending[session]
        }

        func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
            answered.append((approval, allow))
            guard accepts else { return false }
            pending[approval.session] = nil
            return true
        }
    }

    static func approval(_ session: String) -> AgentApproval {
        AgentApproval(session: session, permission: "perm-\(session)", digest: "d-\(session)", summary: "Run tests")
    }

    static func lane(_ id: String, _ state: AgentActivityLane.State, peer: String? = nil, since: Date? = nil) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: peer, parent: nil, state: state, since: since, error: nil, workspaceID: nil)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func onlyThisMacsWaitingChatsAreReadAndOnlyWhileASurfaceIsOn() {
        let store = AgentLaneStore()
        store.lanes = ["s1": Self.lane("s1", .input), "s2": Self.lane("s2", .working),
                       "peer": Self.lane("peer", .input, peer: "huge-blue")]
        #expect(SidebarApprovals.waitingChats(in: store, enabled: false).isEmpty, "both surfaces off (the defaults): nothing is read")
        #expect(Set(SidebarApprovals.waitingChats(in: store, enabled: true).keys) == ["s1"], "another machine's chat answers there")
    }

    @Test func aWaitingChatsPromptIsReadOnceAndItsRowAnswersIt() async {
        let answerer = Answerer()
        answerer.pending = ["s1": Self.approval("s1")]
        let approvals = SidebarApprovals(answerer: answerer)
        let wait = ["s1": SidebarApprovals.Wait(since: Date(timeIntervalSince1970: 1), step: nil)]
        approvals.sync(wait)
        await settle { approvals.approvals["s1"] != nil }
        #expect(approvals.approvals["s1"] == Self.approval("s1"))
        approvals.sync(wait)
        #expect(answerer.lookups == ["s1"], "a lane event on the same wait reads nothing again")

        approvals.answer(session: "s1", request: "perm-s1", allow: true)
        #expect(approvals.approvals["s1"] == nil, "the buttons go at once: a second press answers nothing")
        await settle { answerer.lookups.count == 2 }
        #expect(answerer.answered.map(\.allow) == [true])
        #expect(answerer.answered.first?.approval == Self.approval("s1"))
        #expect(answerer.lookups == ["s1", "s1"], "answered: the chat's next prompt, if any, is read")
        #expect(approvals.approvals["s1"] == nil)

        approvals.sync([:])
        #expect(approvals.approvals.isEmpty)
    }

    @Test func aRefusedAnswerLeavesTheRowWithoutButtons() async {
        let answerer = Answerer()
        answerer.pending = ["s1": Self.approval("s1")]
        answerer.accepts = false
        let approvals = SidebarApprovals(answerer: answerer)
        approvals.sync(["s1": SidebarApprovals.Wait(since: nil, step: "Bash")])
        await settle { approvals.approvals["s1"] != nil }
        approvals.answer(session: "s1", request: "perm-s1", allow: false)
        await settle { !answerer.answered.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        #expect(answerer.answered.map(\.allow) == [false])
        #expect(approvals.approvals["s1"] == nil, "the prompt ended or changed: the row opens the chat instead")
        #expect(answerer.lookups == ["s1"])
    }

    @Test func theTrayFindsTheWorkspaceThatShowsAnAnswerableChat() {
        let here = "install:this-mac"
        let chats: [(WorkspaceID, [AgentSessionRef])] = [
            (WorkspaceID("ws-1"), [AgentSessionRef(host: here, session: "s0"), AgentSessionRef(host: here, session: "s1")]),
            (WorkspaceID("ws-2"), [AgentSessionRef(host: "install:other-mac", session: "s2")]),
            (WorkspaceID("ws-3"), [AgentSessionRef(host: here, session: "s3")]),
        ]
        let found = SidebarSessionTreeFeed.workspaces(showing: ["s1", "s2"], in: chats, localHost: here)
        #expect(found == [WorkspaceID("ws-1"): "s1"], "another machine's tab never answers here, whatever its id")
        #expect(SidebarSessionTreeFeed().workspaces(showing: ["s1"]).isEmpty, "before the feed starts nothing is found")
    }

    @Test func thePriorityFeedMarksAnswerableRowsAndRoutesTheirAnswers() async throws {
        let store = AgentLaneStore()
        store.lanes = ["s1": Self.lane("s1", .input), "s2": Self.lane("s2", .input), "s3": Self.lane("s3", .working)]
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }) { _, _ in }
        let answerer = Answerer()
        answerer.pending = ["s1": Self.approval("s1"), "s3": Self.approval("s3")]
        let approvals = SidebarApprovals(answerer: answerer)
        let feed = SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                       hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {}),
                                       chats: chats)
        feed.approvals = approvals
        approvals.sync(["s1": .init(since: nil, step: nil), "s3": .init(since: nil, step: nil)])
        await settle { approvals.approvals.count == 2 }
        let entries = try #require(feed.panel()?.entries)
        #expect(Set(entries.filter(\.answerable).map(\.id)) == ["s1"], "only a row that waits on the person answers")
        feed.perform(.answer("s1", request: "perm-s1", allow: false))
        await settle { !answerer.answered.isEmpty }
        #expect(answerer.answered.map(\.approval.session) == ["s1"])
        #expect(answerer.answered.map(\.allow) == [false])
        #expect(SidebarPriorityRowActions.route(.answer("s1", request: "perm-s1", allow: true)) == nil, "an answer is no registered row action")
    }

    @Test func aPriorityRowsButtonsAndKeysAnswer() throws {
        let entry = SidebarPriorityEntry(id: "s1", title: "Fix login", preview: "Run tests?", state: .needsYou, answerRequest: "perm-s1")
        let row = SidebarPriorityRowView(entry: entry)
        var actions: [SidebarPriorityAction] = []
        row.onAction = { actions.append($0) }
        #expect(!row.answers.isHidden)
        #expect(SidebarPriorityRowView.height(entry) > SidebarPriorityRowView.height(hasPreview: true),
                "Allow and Deny take a line of their own, the preview keeps its two")
        #expect(row.answers.allow.accessibilityPerformPress())
        #expect(row.answers.deny.accessibilityPerformPress())
        row.keyDown(with: try Self.key("y"))
        row.keyDown(with: try Self.key("n"))
        row.keyDown(with: try Self.key("y", modifiers: .command))
        row.keyDown(with: try Self.key("y", repeating: true))
        let allow = SidebarPriorityAction.answer("s1", request: "perm-s1", allow: true)
        let deny = SidebarPriorityAction.answer("s1", request: "perm-s1", allow: false)
        #expect(actions == [allow, deny, allow, deny], "a held y's repeats answer nothing")

        var plain = entry
        plain.answerRequest = nil
        row.configure(plain)
        #expect(row.answers.isHidden)
        actions = []
        row.keyDown(with: try Self.key("y"))
        #expect(actions.isEmpty, "a row that cannot answer leaves y alone")
    }

    @Test func aTrayItemsButtonsAndKeysAnswer() throws {
        let tray = SidebarNeedsYouTrayView()
        var needsYou = SidebarNeedsYou()
        needsYou.items = [SidebarNeedsYouItem(id: WorkspaceID("ws-1"), title: "Fix login", path: [], reason: .waiting, kind: .permission),
                          SidebarNeedsYouItem(id: WorkspaceID("ws-2"), title: "Docs", path: [], reason: .waiting, kind: .question)]
        tray.show(needsYou)
        tray.setAnswerable([WorkspaceID("ws-1"): "perm-1"])
        var answers: [(WorkspaceID, String, Bool)] = []
        tray.onAnswer = { answers.append(($0, $1, $2)) }
        #expect(!tray.rows[0].answers.isHidden)
        #expect(tray.rows[1].answers.isHidden, "a question is answered in its chat")
        #expect(tray.rows[0].acceptsFirstResponder)
        #expect(!tray.rows[1].acceptsFirstResponder)
        #expect(tray.rows[0].answers.deny.accessibilityPerformPress())
        tray.rows[0].keyDown(with: try Self.key("y"))
        tray.rows[0].keyDown(with: try Self.key("y", repeating: true))
        #expect(answers.map(\.0) == [WorkspaceID("ws-1"), WorkspaceID("ws-1")])
        #expect(answers.map(\.1) == ["perm-1", "perm-1"])
        #expect(answers.map(\.2) == [false, true], "a held y's repeats answer nothing")

        // The slot shows another chat, or the same chat's next request: its buttons answer that one.
        let first = tray.rows[0].answers.target
        tray.setAnswerable([WorkspaceID("ws-1"): "perm-2"])
        #expect(tray.rows[0].answers.target != first)
        needsYou.items.removeFirst()
        needsYou.items.insert(SidebarNeedsYouItem(id: WorkspaceID("ws-3"), title: "Deploy", path: [], reason: .waiting,
                                                  kind: .permission), at: 0)
        tray.setAnswerable([WorkspaceID("ws-1"): "perm-2", WorkspaceID("ws-3"): "perm-3"])
        let second = tray.rows[0].answers.target
        tray.show(needsYou)
        #expect(tray.rows[0].answers.target != second)

        tray.setAnswerable([:])
        #expect(tray.rows[0].answers.isHidden)
        #expect(!tray.rows[0].acceptsFirstResponder)
    }

    @Test func onlyTheBareLettersAnswer() {
        #expect(SidebarAnswerKey(characters: "y", modifiers: []) == .allow)
        #expect(SidebarAnswerKey(characters: "N", modifiers: .shift) == .deny)
        #expect(SidebarAnswerKey(characters: "y", modifiers: .command) == nil)
        #expect(SidebarAnswerKey(characters: "n", modifiers: .option) == nil)
        #expect(SidebarAnswerKey(characters: "a", modifiers: []) == nil)
        #expect(SidebarAnswerKey(characters: "y", modifiers: [], repeating: true) == nil,
                "holding y never answers the next prompt to arrive")
    }

    @Test func aPressAnswersOnlyTheRequestItBeganOn() throws {
        let answers = SidebarAnswerButtons(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        answers.layout()
        var pressed: [Bool] = []
        answers.onAnswer = { pressed.append($0) }
        let button = answers.allow
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        answers.target = "s1\u{1F}perm-1"
        button.mouseDown(with: try Self.mouse(.leftMouseDown, at: point))
        button.mouseUp(with: try Self.mouse(.leftMouseUp, at: point))
        #expect(pressed == [true], "a press and release on one request answers it")

        button.mouseDown(with: try Self.mouse(.leftMouseDown, at: point))
        answers.target = "s1\u{1F}perm-2"
        button.mouseUp(with: try Self.mouse(.leftMouseUp, at: point))
        #expect(pressed == [true], "the request changed under the press: its release answers nothing")
    }

    @Test func anAnswerForAnEndedRequestAnswersNothing() async {
        let answerer = Answerer()
        answerer.pending = ["s1": Self.approval("s1")]
        let approvals = SidebarApprovals(answerer: answerer)
        approvals.sync(["s1": SidebarApprovals.Wait(since: nil, step: nil)])
        await settle { approvals.approvals["s1"] != nil }
        approvals.answer(session: "s1", request: "perm-earlier", allow: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(answerer.answered.isEmpty, "a press that began on an earlier request never answers the next one")
        #expect(approvals.approvals["s1"] == Self.approval("s1"), "the row keeps its buttons for the request it shows")
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    static func key(_ character: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: character, charactersIgnoringModifiers: character,
                                      isARepeat: repeating, keyCode: character == "y" ? 16 : 45))
    }
}
