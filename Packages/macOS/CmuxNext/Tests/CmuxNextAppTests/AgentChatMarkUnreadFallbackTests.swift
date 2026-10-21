@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDaemonService
import Testing

/// Mark Tab Unread on a read agent chat: acpmux keeps the chat unread when it
/// serves `_acpmux/markUnread`; an acpmux that refuses no longer ends in "Marking
/// as unread is not available yet": the tab's daemon mark (`tab-mark-unread-v1`)
/// marks it instead, and only when both refuse does the run say why (the
/// daemon's reason).
@MainActor @Suite struct AgentChatMarkUnreadFallbackTests {
    struct Refused: Error {}

    @Test func acpmuxMarksTheChatAndTheDaemonIsNotAsked() async throws {
        var daemonMarks = 0
        try await AgentChatMarkUnread(acpmux: { true }, daemon: { daemonMarks += 1 }).run()
        #expect(daemonMarks == 0)
    }

    @Test func anAcpmuxThatRefusesFallsBackToTheDaemonMark() async throws {
        var daemonMarks = 0
        try await AgentChatMarkUnread(acpmux: { false }, daemon: { daemonMarks += 1 }).run()
        #expect(daemonMarks == 1)
    }

    @Test func whenBothRefuseTheRunThrowsTheDaemonsReason() async {
        await #expect(throws: ActionFailure.self) {
            try await AgentChatMarkUnread(acpmux: { false }, daemon: { throw ActionFailure(message: "restart the daemon") }).run()
        }
    }
}
