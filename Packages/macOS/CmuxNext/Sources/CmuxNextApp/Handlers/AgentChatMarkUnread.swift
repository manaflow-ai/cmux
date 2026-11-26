import CmuxNextDaemonService

/// Mark Tab Unread on a read agent chat: acpmux keeps the chat unread until
/// it is shown again (`_acpmux/markUnread`, cx-ncc.78); an acpmux that
/// refuses (an older one) falls back to the tab's daemon mark
/// (`tab-mark-unread-v1`, ``TabUnreadMark``), so the run never ends in "not
/// available". Only when both refuse does it throw (the daemon's reason).
@MainActor
struct AgentChatMarkUnread {
    let acpmux: @MainActor () async -> Bool
    let daemon: @MainActor () throws -> Void

    func run() async throws {
        if await acpmux() { return }
        try daemon()
    }
}
