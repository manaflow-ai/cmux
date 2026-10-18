import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFloating

extension NotificationCenterService {
    /// An arrival that stays unread goes to the Chief pet when it would alert here, by a banner's
    /// rules (muted workspaces, quiet hours, `notifications.desktop`) whether or not its poster asked for one.
    func notifyChiefPet(_ notification: DaemonNotification, located: LocatedTab, decision: NotificationPolicy.Decision, program: ProgramStatusNotification?) {
        guard decision.alerts, let chiefPet else { return }
        chiefPet.alerted(ChiefPetNotice(notification, tab: located.tab.id, tabTitle: located.tab.displayTitle, workspace: located.workspace.displayName,
                                        programTitle: program?.title(localizations: localizations), body: notification.bannerBody(previews: previews, screenLocked: screenLocked()),
                                        reply: located.tab.kind == .pty ? .type : located.tab.agentSession == nil ? .openTab : .openChat,
                                        session: located.tab.agentSession.flatMap { services?.madeAgentTabs?.session(of: located.tab.id) ?? $0.session }))
    }

    /// Pastes `text` into `located`'s terminal, then Return as its own key, on the tab's own machine (a
    /// Cloud terminal's input goes over its link): a reply answered the tab, so it is read. False for a non-terminal.
    @discardableResult
    func type(_ text: String, into located: LocatedTab) -> Bool {
        guard let services, !text.isEmpty, located.tab.kind == .pty else { return false }
        let target = located.tab.surface
        services.daemon(for: located.pane).send("notification-reply") { connection in
            try await connection.send(target, text: text, paste: true)
            try await connection.send(target, text: "\r")
        }
        note("reply \(located.tab.id)")
        acknowledge(located.tab)
        return true
    }
}
