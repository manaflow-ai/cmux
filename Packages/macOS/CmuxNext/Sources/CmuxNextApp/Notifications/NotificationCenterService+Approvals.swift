import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextSettings

/// Wiring of agent chat approval banners (cx-kz6m0.2, ``AgentApprovalBanners``): an agent's ask
/// on a chat tab whose session runs on this Mac's acpmux gets Allow once and Deny.
extension NotificationCenterService {
    func followApprovals(_ services: AppServices) {
        if approvals.answerer == nil, let environment = QuitAgents.environment(services) {
            approvals.answerer = AcpmuxApprovalAnswerer(environment: environment)
        }
        localAgentHost = { [weak services] in services?.agentTabs.localHost }
        desktop.onApprove = { [weak self] id, surface, allow in
            self?.answerApproval(banner: id, surface: surface.map(SurfaceID.init(rawValue:)), allow: allow)
        }
    }

    /// Runs `post` with the chat's pending permission when `notification` is an agent's ask (a
    /// warning) on a chat of this Mac; at once with nil otherwise (a terminal agent's hook
    /// approval has no prompt this app can answer).
    func withApproval(of notification: DaemonNotification, tab: TabModel?, post: @escaping @MainActor (AgentApproval?) -> Void) {
        guard let tab else { return post(nil) }
        guard approvals.answerer != nil, notification.source == NotificationSource.agent.rawValue, notification.level == .warning,
              let ref = tab.agentSession, let session = ref.session, let local = localAgentHost(), ref.host == local else {
            approvals.forget(tab: tab.id, retire: false)
            return post(nil)
        }
        let id = notification.notification.rawValue
        approvals.read(session: session, notification: id, tab: tab.id, stillUnread: {
            guard let marker = tab.notification else { return true }
            return marker.notification.rawValue < id || (marker.notification.rawValue == id && marker.unread)
        }, post: post)
    }

    /// Allow once or Deny on an approval banner of this launch. An answered prompt reads the tab;
    /// one that ended or changed opens it, where the chat shows what it waits on now.
    func answerApproval(banner: String, surface: SurfaceID?, allow: Bool) {
        guard let entry = approvals.take(banner), let answerer = approvals.answerer else {
            return note("approval refused: \(banner) is not an approval banner of this launch")
        }
        // task-owner: NotificationCenterService.answerApproval: one answer per banner button.
        Task { @MainActor [weak self] in
            let answered = await answerer.answer(entry.approval, allow: allow)
            self?.note("approval \(allow ? "allow" : "deny") \(entry.tab) \(answered ? "answered" : "not answered")")
            guard let self, let services = self.services else { return }
            if !answered { return self.open(surface: surface) }
            if let tab = Self.tab(id: entry.tab, in: services.daemon.store) { self.acknowledge(tab) }
        }
    }
}
