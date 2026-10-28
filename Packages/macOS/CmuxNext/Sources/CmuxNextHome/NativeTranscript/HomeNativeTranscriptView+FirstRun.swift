public import AppKit
import CmuxNextDesign

/// The first-run panel's inputs from the host (`HomeFirstRunView`): shortcuts, agents, the
/// Chief's face, the pet row's state and the hero's Debug Settings switch; and the
/// conversation's own notice row.
extension HomeNativeTranscriptView {
    /// A notice about the conversation itself (Home's merge notice): a row of
    /// the transcript, under the newest message; nil removes it.
    public func showConversationNotice(_ text: String?) {
        guard transcript.notice != text else { return }
        transcript.notice = text
        if let text {
            NSAccessibility.post(element: transcript, notification: .announcementRequested, userInfo: [.announcement: text])
        }
    }

    /// The first-run rows' shortcuts and the Switching card's keys, as the
    /// live binding table has them; nil hides one (nil `switching`: no card).
    public func setFirstRunShortcuts(terminal: String?, agent: String?, switching: HomeSwitchKeys?) {
        firstRun.setShortcuts(terminal: terminal, agent: agent, switching: switching)
    }

    /// The Chief's avatar as the host resolved it (its picture, else its text: the profile's, or
    /// 🫡 for a Chief with none, `HomeChiefAvatar.headerText`), on the header and the first-run hero.
    public func setChiefAvatar(picture: NSImage?, text: String?) {
        avatarPicture = picture
        avatarText = text
        firstRun.hero.setAvatar(picture: picture, text: text)
    }

    /// The user's agents for the first-run panel's glance (the host maps
    /// them from the tab status the strip and the sidebar draw); empty lists
    /// none.
    public func setFirstRunAgents(_ agents: [HomeAgentGlance]) {
        firstRun.setAgents(agents)
    }
}
