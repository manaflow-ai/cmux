import AppKit
import CmuxNextChiefPetWiring
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextWakeups

/// The transcript header's live parts: its top-right panel toggles and the Chief's avatar.
extension HomeHostView {
    /// What this Home's header toggles read and act on: its window and its conversation's Chief.
    var headerPanelContext: HomeHeaderPanelContext {
        HomeHeaderPanelContext(services: control.services, window: window.flatMap { control.services.windows.owner(of: $0) },
                               isChief: isChief, chief: control.named, server: control.server?.machineID)
    }

    /// The header's top-right toggles (``HomeHeaderPanels``) follow their panels while this Home
    /// is shown: one observation of what they read (the tree's page tabs, the window's right
    /// sidebar, the shortcuts, the Debug Settings toggle) on the view's node, so a hidden Home reads
    /// none of it, no polling. Restarted when the view changes windows (`viewDidMoveToWindow`) or the
    /// conversation becomes (or stops being) a Chief's.
    func watchHeaderPanels() {
        headerPanelsWatch?.cancel()
        headerPanelsWatch = nil
        guard window != nil else { return transcript.setHeaderPanels([]) }
        let context = headerPanelContext
        headerPanelsWatch = VisibleObservation(visibilityNode, owner: "HomeHost.headerPanels", on: mainWork) {
            HomeHeaderPanels.items(context)
        } apply: { [weak self] items in
            self?.transcript.setHeaderPanels(items)
        }
    }

    // MARK: Avatar

    /// Where this Chief's picture is kept: the daemon's Chief registry for a Chief of this Mac
    /// (the store the profile and chiefs tools write); nil for a cloud Chief (its files).
    private func pictureStore() -> (avatars: HomeChiefAvatars, chief: String)? {
        guard !control.isCloud else { return nil }
        let avatars = HomeChiefAvatars(muxHome: HomeBrainHost.muxHome(tag: control.services.environment.tag),
                                       registry: DaemonChiefAvatarRegistry(connection: control.connection),
                                       files: control.services.work)
        return (avatars, HomeChiefAvatars.chiefID(named: control.named))
    }

    /// The picture of the pet character the Chief shown here wears (its own pick).
    private var characterPicture: URL? {
        ChiefPetSettingsRows.avatarURL(of: control.services.chiefMascotPicks.mascot(of: petRows.chief, in: control.services.settings?.snapshot))
    }

    /// The header avatar of the Chief shown here: its registry picture, else its profile's text,
    /// else its own pet character. The read runs off the main actor and its result is shown as
    /// visible work (recipe R-hop, plans/cmux-next/chrome-parity/p06-scheduler.md).
    func loadAvatar() {
        let home = control.brainHome
        let files = HomeChiefFiles(muxHome: home)
        let store = pictureStore()
        let lanes = control.services.work
        // A cloud Chief's picture is its own files under the brain home.
        settingsView.pictureStore = store ?? (HomeChiefAvatars(muxHome: home, files: lanes), HomeChiefAvatars.defaultChief)
        let fallback = characterPicture, work = mainWork
        // task-owner: one avatar read (registry, else files); its result is posted as visible work, then it ends
        control.services.work.task(.userVisible) { [weak self] in
            let avatar = if let store {
                await store.avatars.headerAvatar(chief: store.chief, fallback: fallback)
            } else {
                await HomeChiefAvatars.headerAvatar(files: files, fallback: fallback, on: lanes)
            }
            work.postFromAnyThread(.visible, owner: "HomeHost.chiefAvatar") { [weak self] in
                // A read for the Chief or the character shown before (another came in since) is dropped.
                guard let self, control.brainHome == home, fallback == characterPicture else { return }
                let picture = avatar.picture.flatMap(NSImage.init(data:))
                let text = HomeChiefAvatar.headerText(avatar.text, hasPicture: picture != nil)
                transcript.setChiefAvatar(picture: picture, text: text)  // the header and the first-run hero
                settingsView.setAvatar(picture: picture, text: text)
            }
        }
    }
}
