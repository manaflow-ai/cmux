import CmuxNextCompat
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Observation

/// The Home list's first frame at launch is the list as it was at the last quit (Lawrence
/// 2026-10-21: "loading stat here is bad on app launch"). Every input of the list loads on its own
/// after launch: the conversations (`HomeCache`, read by the store), each owner's `home-inbox` order
/// and pins, each Chief's avatar and engine, the archived Chiefs and the cloud Chiefs (Main, where
/// each runs). Before, the first frames drew this Mac's old order, the default avatar, no tags and
/// archived Chiefs, and each piece popped in. Now the last state is read synchronously from disk
/// before the list is made, and every live answer replaces its piece in place.
extension HomeService {
    /// Reads the last launch's list into the store, the inboxes, the directory and the roster;
    /// once, before the Home list's first frame (`makeSidebarSource`, `start`).
    func primeHomeList() {
        guard !homeListPrimed else { return }
        homeListPrimed = true
        // Both files were read and decoded off the main thread since `main` (LaunchFiles, #17587): here they
        // are only taken. Without a launch read (tests) they are read here.
        let launch = services.environment.launchFiles?.home
        if let launch { launch.prime(homeStore) } else { homeStore.primeFromCache() }
        guard let last = launch.map({ $0.lastList(sidebarLaunch, account: pinAccount) }) ?? sidebarLaunch.load(account: pinAccount) else { return }
        last.seed([homeInbox, homeCloudInbox])
        directory.seedLaunch(last)
        launchRoster = last.roster
    }

    /// Writes the list's state for the next launch after each change (coalesced, off the main actor).
    func keepHomeListForLaunch() {
        guard launchListObservation == nil else { return }
        let source = groupMuting
        let cache = sidebarLaunch
        let directory = directory
        // task-owner: lives as long as the service; event-driven (Observation)
        launchListObservation = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in
                (self?.homeInbox.reply, self?.homeCloudInbox.reply, directory.chiefAvatars, directory.chiefHarnesses,
                 directory.archivedChiefs, self?.chiefRoster)
            }) {
                guard self != nil else { return }
                cache.save(source.launchSnapshot(archivedChiefs: directory.archivedChiefs))
            }
        }
    }
}
