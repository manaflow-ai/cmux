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

    /// The first-run panel's "Bring your memory from …" row (what the host found on this Mac); nil removes it.
    public func setFirstRunMemoryOffer(_ title: String?) {
        firstRun.setMemoryOffer(title)
    }

    /// Shows the Chief's first-open message above the first-run panel's hero: the welcome or a new
    /// Chief's focus question, as ``ChiefIntroStore`` picks it; the bubble rises in the first time it shows.
    /// - Parameter kind: Which intro shows.
    public func showFirstRunIntro(_ kind: ChiefIntroKind = .welcome) {
        firstRun.setIntro(HomeStrings.chiefIntro(kind))
    }

    /// The Chief's avatar as the host resolved it (its picture, else its text: the profile's, or
    /// 🫡 for a Chief with none, `HomeChiefAvatar.headerText`), on the header and the first-run hero.
    public func setChiefAvatar(picture: NSImage?, text: String?) {
        avatarPicture = picture
        avatarText = text
        firstRun.hero.setAvatar(picture: picture, text: text)
    }

    /// Whether the Chief pet shows (`DesignSettings.homeChiefPetEnabled`, from `home.chiefPetEnabled`):
    /// the first-run panel's pet row reads Show or Hide Chief Pet.
    func followChiefPet() {
        withObservationTracking {
            firstRun.setPetShown(DesignSettings.shared.homeChiefPetEnabled)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followChiefPet() }
        }
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
