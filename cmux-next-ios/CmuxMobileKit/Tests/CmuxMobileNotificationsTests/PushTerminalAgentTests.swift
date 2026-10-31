import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileNotifications

/// A terminal agent's events (Claude Code or Codex in a terminal tab, reported by its hook)
/// push as what happened, so "Needed and finished" reaches them. They name no agent chat, so
/// they take a terminal's buttons: no Reply, Allow or Deny that would fail.
@Suite struct PushTerminalAgentTests {
    func payload(_ kind: PushKind, session: String? = nil, notification: String? = "20") -> PushPayload {
        PushPayload(mac: "m", macName: "Mac", kind: kind, agent: "Claude", place: "cmux-next", workspaceId: "ws_a", tabId: "s7",
                    sessionId: session, notificationId: notification, title: kind == .permission ? "Bash" : nil, state: .finished)
    }

    @Test func aTerminalAgentsFinishedTurnTakesNoReply() {
        let finished = payload(.completed)
        #expect(finished.fromTerminalAgent)
        #expect(finished.category == .terminal)
        #expect(PushActions().plan(for: finished).isEmpty)
        #expect(!PushForm(payload: finished).hasComposer)
        // A chat's finished turn keeps its Reply.
        let chat = payload(.completed, session: "sess-1", notification: nil)
        #expect(!chat.fromTerminalAgent && chat.category == .completed)
        #expect(PushActions().plan(for: chat).map(\.action) == [.reply])
    }

    @Test func aTerminalAgentsApprovalOpensItsTab() {
        let approval = payload(.permission)
        #expect(approval.category == .terminal)
        #expect(PushActions().plan(for: approval).map(\.action) == [.answer])
        #expect(PushBanner(payload: approval).title == "Claude needs permission")
        let error = payload(.failed)
        #expect(error.category == .terminal && PushActions().plan(for: error).isEmpty)
    }

    @Test func questionsChiefAndProgramAlertsKeepTheirCategories() {
        #expect(payload(.terminal).category == .terminal)
        #expect(!payload(.question).fromTerminalAgent)
        #expect(!payload(.chief, session: "turn-1", notification: nil).fromTerminalAgent)
    }

    @Test func theServiceExtensionGivesAnOlderWorkersCategoryThePhones() throws {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = PushCategory.completed.rawValue
        content.userInfo = payload(.completed).userInfo
        let fixed = try #require(ServicePush().categorized(content))
        #expect(fixed.categoryIdentifier == PushCategory.terminal.rawValue)
        // Already the phone's: left as it came.
        content.categoryIdentifier = PushCategory.terminal.rawValue
        #expect(ServicePush().categorized(content) == nil)
        content.categoryIdentifier = PushCategory.completed.rawValue
        content.userInfo = payload(.completed, session: "sess-1", notification: nil).userInfo
        #expect(ServicePush().categorized(content) == nil)
    }
}
