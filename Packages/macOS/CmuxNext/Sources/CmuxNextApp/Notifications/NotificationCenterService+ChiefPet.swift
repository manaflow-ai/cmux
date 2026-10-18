import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFloating

extension NotificationCenterService {
    /// An arrival that stays unread goes to the Chief pet when it would alert here, by a banner's
    /// rules (muted workspaces, quiet hours, `notifications.desktop`) whether or not its poster asked for one.
    func notifyChiefPet(_ notification: DaemonNotification, located: LocatedTab, decision: NotificationPolicy.Decision, program: ProgramStatusNotification?) {
        guard decision.alerts, let chiefPet else { return }
        chiefPet.alerted(ChiefPetNotice(notification, tab: located.tab.id, tabTitle: located.tab.displayTitle, workspace: located.workspace.displayName,
                                        programTitle: program?.title(localizations: localizations), body: notification.bannerBody(previews: previews, screenLocked: screenLocked())))
    }
}
