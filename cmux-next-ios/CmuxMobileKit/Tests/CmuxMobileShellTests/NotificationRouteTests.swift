import CmuxMobileAgentChat
import Foundation
import CmuxMobileModel
import CmuxMobileNotifications
import Testing
import UserNotifications
@testable import CmuxMobileShell

#if os(iOS)
/// A tap opens the notification's exact screen on its Mac (verify/rich-push.md, "Tap routing").
@MainActor @Suite struct NotificationRouteTests {
    let chat = AgentChatDestination(workspaceID: "w1", tabID: "t-chat")

    func workspace(_ id: String, mac: String, tabs: [String]) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "/w", tabs: tabs.map { WorkspaceTab(id: $0, kind: .terminal, title: $0) },
                  lastActivityAt: Date())
    }

    func decide(_ route: NotificationRoute, chat: AgentChatDestination? = nil, workspaces: [Workspace] = [],
                phase: MacDataMachine.Phase = .live) -> NotificationTarget {
        NotificationTarget.decide(route, chat: { _ in chat }, workspace: { id in workspaces.first { $0.id == id } }, phase: { _ in phase })
    }

    @Test func chiefOpensChief() {
        #expect(decide(NotificationRoute(kind: "chief", mac: "m", conversationID: "home")) == .chief)
    }

    @Test func anAgentEventOpensItsChat() {
        #expect(decide(NotificationRoute(kind: "question", mac: "m", sessionID: "s"), chat: chat) == .chat(chat))
    }

    @Test func aTerminalNotificationOpensItsTab() {
        let ws = workspace("w2", mac: "m", tabs: ["s7", "s8"])
        let route = NotificationRoute(kind: "terminal", mac: "m", workspaceID: "w2", tabID: "s8")
        // Even when some chat is bound to that tab id, a terminal opens its terminal.
        #expect(decide(route, chat: chat, workspaces: [ws]) == .workspace(id: "w2", tabID: "s8"))
    }

    @Test func aBrowserTabOpensInItsWorkspace() {
        let ws = workspace("w3", mac: "m", tabs: ["b1"])
        #expect(decide(NotificationRoute(kind: "completed", mac: "m", workspaceID: "w3", tabID: "b1"), workspaces: [ws]) == .workspace(id: "w3", tabID: "b1"))
    }

    @Test func anotherMacsWorkspaceWithTheSameIdIsNotOpened() {
        let ws = workspace("w2", mac: "other", tabs: ["s7"])
        #expect(decide(NotificationRoute(kind: "terminal", mac: "m", workspaceID: "w2", tabID: "s7"), workspaces: [ws]) == .feed)
    }

    @Test func waitsForTheMacsTreeThenFallsBackToTheFeed() {
        let route = NotificationRoute(kind: "completed", mac: "m", sessionID: "s")
        #expect(decide(route, phase: .loading) == .wait)
        #expect(decide(route, phase: .idle) == .wait)
        #expect(decide(route, phase: .live) == .feed)
        #expect(decide(route, phase: .offline) == .feed)
    }
}

@MainActor @Suite struct PushResponseTests {
    let question = PushPayload(mac: "m", macName: "Mac", kind: .question, eventId: "e", sessionId: "s", permissionId: "p",
                               questions: [PushQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])])
    let finished = PushPayload(mac: "m", kind: .completed, sessionId: "s")

    func response(_ id: String, _ payload: PushPayload?, text: String? = nil, retry: PushReply? = nil) -> PushReplies.Response {
        PushReplies.Response(actionIdentifier: id, text: text, payload: payload, retry: retry)
    }

    @Test func aTapOpens() {
        #expect(PushReplies.outcome(response(UNNotificationDefaultActionIdentifier, question)) == .open(question))
        #expect(PushReplies.outcome(response("cmux.answer", question)) == .open(question))
        #expect(PushReplies.outcome(response(UNNotificationDismissActionIdentifier, question)) == .nothing)
    }

    @Test func anOptionOpensTheAppAndWaitsForFaceID() {
        guard case .foreground(let reply, let open) = PushReplies.outcome(response("cmux.option.1", question)) else {
            Issue.record("not foreground")
            return
        }
        #expect(reply.action == .option(1) && open == question)
    }

    @Test func aReplyGoesInTheBackground() {
        guard case .background(let reply) = PushReplies.outcome(response("cmux.reply", finished, text: "go")) else {
            Issue.record("not background")
            return
        }
        #expect(reply.action == .text("go", attachments: []) && reply.mac == "m")
        #expect(PushReplies.outcome(response("cmux.reply", finished, text: " ")) == .nothing)
    }

    @Test func retryResendsInTheForeground() throws {
        let reply = try #require(PushReply(payload: finished, button: .reply, text: "go"))
        #expect(PushReplies.outcome(response(UNNotificationDefaultActionIdentifier, nil, retry: reply)) == .foreground(reply, open: nil))
        #expect(PushReplies.outcome(response("cmux.retry", nil, retry: reply)) == .foreground(reply, open: nil))
    }
}
#endif
