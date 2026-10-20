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

    /// The header avatar from the Chief's profile: its picture, else its text, else the Chief
    /// pet's character (`HomeChiefFace`), which follows the setting live (`followChiefPet`).
    public func setChiefAvatar(picture: NSImage?, text: String?) {
        profileAvatar = (picture, text)
        applyChiefAvatar()
    }

    private func applyChiefAvatar() {
        guard let profile = profileAvatar else { return }
        avatarPicture = profile.picture ?? (profile.text == nil ? HomeChiefFace().picture : nil)
        avatarText = profile.text
        onChiefAvatar?(avatarPicture, profile.text)
    }

    /// The Chief pet's character and whether it shows (`DesignSettings`, from `home.chiefPetMascot`
    /// and `home.chiefPetEnabled`): the first-run hero's picture, its pet row and the default face.
    func followChiefPet() {
        withObservationTracking {
            firstRun.hero.image = HomeChiefFace().picture
            firstRun.setPetShown(DesignSettings.shared.homeChiefPetEnabled)
            applyChiefAvatar()
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
