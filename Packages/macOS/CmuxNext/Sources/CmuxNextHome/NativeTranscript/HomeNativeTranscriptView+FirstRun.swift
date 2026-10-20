import AppKit
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

    /// The Chief's face over the first-run panel: the Chief pet's character
    /// (`home.chiefPetMascot`); nil draws none.
    public func setFirstRunPicture(_ image: NSImage?) {
        firstRun.hero.image = image
    }

    /// Whether the Chief pet shows: the panel's pet row reads Hide Chief Pet while it does.
    public func setFirstRunPetShown(_ shown: Bool) {
        firstRun.setPetShown(shown)
    }

    /// The user's agents for the first-run panel's glance (the host maps
    /// them from the tab status the strip and the sidebar draw); empty lists
    /// none.
    public func setFirstRunAgents(_ agents: [HomeAgentGlance]) {
        firstRun.setAgents(agents)
    }

    /// Debug Settings > Home > Chief front page hero: off keeps the rows-only first-run panel.
    func followHeroTunable() {
        withObservationTracking {
            firstRun.showsHero = HomeTunables.firstRunHero.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followHeroTunable() }
        }
    }
}
