import CmuxNextCompat
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextLaunch
import CmuxNextWakeups
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
        homeStore.primeFromCache()
        guard let last = sidebarLaunch.load(account: pinAccount) else { return }
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

    /// Posts ``start()`` (the Chief owner and cloud link), the chats feed and its importers and the New Tab
    /// page's feeds: never before the first frame. Each is one ``LaunchNeedPosts`` start, after startup by
    /// default; right after the first frame once a Home view or an agent page shows (`TopHomePageView`,
    /// ``homeDidOpen(asked:)``, `AgentTabStore.pageShown`), as Chrome starts what a visible tab needs first
    /// and posts the rest through `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc).
    /// A Home view's first frame is the last launch's list (``primeHomeList()``), so it waits for none of them.
    /// The pages' chat clicks and All chats pager are wired at launch (`AgentPageChats.wirePager`): no feed.
    func postLaunchFeeds(startup: StartupScheduler) {
        let services = self.services
        let feeds = LaunchNeedPosts(startup: startup, starts: [
            .init("Home.start", needed: "Home.startNeeded") { [weak self] in self?.start() },
            .init("ChatsFeed.keepCurrent", needed: "ChatsFeed.keepCurrentNeeded") { [weak services] in services?.chatsFeed?.keepCurrent() },
            .init("ProjectsImport.start", needed: "ProjectsImport.startNeeded") { [weak services] in if let services { services.projectsImport.start(feed: services.chatsFeed) } },
            .init("AgentPageChats.wire", needed: "AgentPageChats.wireNeeded") { [weak services] in
                if let services, let feed = services.chatsFeed { AgentPageChats.wire(services.agentTabs, to: feed, opener: services.chatsOpener) }
            },
            .init("NewTabClosed.wire", needed: "NewTabClosed.wireNeeded") { [weak services] in if let services { NewTabClosed.wire(services.agentTabs, services: services) } },
            .init("NewTabPlacesFeed.wire", needed: "NewTabPlacesFeed.wireNeeded") { [weak services] in if let services { NewTabPlacesFeed.wire(services.agentTabs, services: services) } },
            .init("NewTabWeather.wire", needed: "NewTabWeather.wireNeeded") { [weak services] in if let services { NewTabWeather.wire(services.agentTabs, services: services) } },
        ])
        launchFeeds = feeds
        feeds.post()
    }
}
