import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Approval banners (cx-kz6m0.2, parity with classic's feed permission banners): an agent chat
/// on this Mac that waits on one tool permission gets a banner that says what it asks to do,
/// with Allow once and Deny. Both answer the chat's prompt through ``approvalAnswerer``, which
/// re-reads the prompt first: an answer counts only for the request the banner showed.
extension NotificationCenterService {
    /// Wires the app's acpmux answerer, this Mac's host id, and the banners' buttons.
    func followApprovals(_ services: AppServices) {
        if approvalAnswerer == nil, let environment = QuitAgents.environment(services) {
            approvalAnswerer = AcpmuxApprovalAnswerer(environment: environment)
        }
        localAgentHost = { [weak services] in services?.agentTabs.localHost }
        desktop.onApprove = { [weak self] id, surface, allow in
            self?.answerApproval(banner: id, surface: surface.map(SurfaceID.init(rawValue:)), allow: allow)
        }
    }

    /// The session whose prompt `notification` may stand for: an agent's ask (a warning) on an
    /// agent chat tab whose session runs on this Mac's acpmux. Nil for everything else (a
    /// terminal agent's hook approval has no prompt this app can answer).
    func approvalSession(of notification: DaemonNotification, tab: TabModel?) -> String? {
        guard approvalAnswerer != nil, notification.source == NotificationSource.agent.rawValue,
              notification.level == .warning, let ref = tab?.agentSession, let session = ref.session,
              let local = localAgentHost(), ref.host == local else { return nil }
        return session
    }

    /// Runs `post` with the chat's pending permission when `notification` stands for one, at
    /// once with nil otherwise. A read that the tab outlived posts nothing: the tab was read
    /// meanwhile (focused, or answered in the chat), or a newer notification of it posted.
    func withApproval(of notification: DaemonNotification, tab: TabModel?,
                      post: @escaping @MainActor (AgentApproval?) -> Void) {
        guard let tab, let session = approvalSession(of: notification, tab: tab), let answerer = approvalAnswerer else {
            if let tab { approvalReads[tab.id] = nil }
            return post(nil)
        }
        let id = notification.notification.rawValue
        approvalReads[tab.id] = id
        // task-owner: NotificationCenterService.withApproval: one prompt read before one banner posts.
        Task { @MainActor [weak self] in
            let approval = await answerer.pendingApproval(session: session)
            guard let self else { return }
            guard self.approvalReads[tab.id] == id else {
                return self.note("approval banner \(id) skipped: \(tab.id) was read or notified again")
            }
            self.approvalReads[tab.id] = nil
            if let marker = tab.notification, marker.notification.rawValue > id || (marker.notification.rawValue == id && !marker.unread) {
                return self.note("approval banner \(id) skipped: \(tab.id) holds no unread \(id)")
            }
            post(approval)
        }
    }

    /// A banner posted on `tab`: it retires the buttons of the tab's older approval banners (one
    /// chat waits on one prompt; the newer banner stands for it), and keeps its own.
    func keepApprovalBanner(_ banner: String, approval: AgentApproval?, tab: String) {
        approvalBanners = approvalBanners.filter { $0.value.tab != tab }
        if let approval { approvalBanners[banner] = (approval, tab) }
    }

    /// Allow once or Deny on an approval banner. Only a banner this launch posted answers, and
    /// only for its own prompt (the answerer re-reads it). An answered prompt reads the tab;
    /// one that ended or changed opens the tab, where the chat shows what it waits on now.
    func answerApproval(banner: String, surface: SurfaceID?, allow: Bool) {
        guard let entry = approvalBanners.removeValue(forKey: banner), let answerer = approvalAnswerer else {
            return note("approval refused: \(banner) is not an approval banner of this launch")
        }
        // task-owner: NotificationCenterService.answerApproval: one answer per banner button.
        Task { @MainActor [weak self] in
            let answered = await answerer.answer(entry.approval, allow: allow)
            guard let self else { return }
            self.note("approval \(allow ? "allow" : "deny") \(entry.tab) \(answered ? "answered" : "not answered")")
            guard let services = self.services else { return }
            if answered, let tab = Self.tab(id: entry.tab, in: services.daemon.store) {
                self.acknowledge(tab)
            } else if !answered {
                self.open(surface: surface)
            }
        }
    }
}
