import CmuxNextAgentLanes
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
/// archived Chiefs, and each piece popped in. Now the last state is read on a launch lane from `main`
/// (``HomeListLaunch``), and every live answer replaces its piece in place.
extension HomeService {
    /// Seeds the store, the inboxes, the directory and the roster with the last launch's list, once, before the list's
    /// first frame (`makeSidebarSource`, `start`): when its read lands (the theme background until then), no file read here.
    func primeHomeList() {
        guard !homeListPrimed else { return }
        homeListPrimed = true
        listLaunch.whenRead { [self] read in  // the service lives as long as the app; the step goes once the read lands
            homeStore.primeFromCache(read.conversations)
            guard let last = read.sidebar, last.account == pinAccount else { return }
            last.seed([homeInbox, homeCloudInbox])
            directory.seedLaunch(last)
            launchRoster = last.roster
        }
    }

    /// Writes the list's state for the next launch after each change (coalesced, off the main actor).
    func keepHomeListForLaunch() {
        guard let services else { return }
        guard launchListObservation == nil else { return }
        let source = groupMuting
        let cache = listLaunch.read.sidebar
        let directory = directory
        // Background: nobody sees the write; it still runs while no Home shows (a service observation).
        launchListObservation = ServiceObservation(.background, owner: "HomeService.launchList", on: services.mainWork) { [weak self] in
            _ = (self?.homeInbox.reply, self?.homeCloudInbox.reply, directory.chiefAvatars, directory.chiefHarnesses,
                 directory.archivedChiefs, self?.chiefRoster)
        } apply: { [weak self] _ in
            guard self != nil else { return }
            cache.save(source.launchSnapshot(archivedChiefs: directory.archivedChiefs))
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
        launchFeeds = LaunchNeedPosts(startup: startup, starts: [
            .init("Home.start", needed: "Home.startNeeded") { [weak self] in self?.start() },
            .init("ChatsFeed.keepCurrent", needed: "ChatsFeed.keepCurrentNeeded") { [weak self] in self?.services?.chatsFeed?.keepCurrent() },
            .init("ProjectsImport.start", needed: "ProjectsImport.startNeeded") { [weak self] in if let s = self?.services { s.projectsImport.start(feed: s.chatsFeed) } },
            .init("AgentPageChats.wire", needed: "AgentPageChats.wireNeeded") { [weak self] in
                if let s = self?.services, let feed = s.chatsFeed { AgentPageChats.wire(s.agentTabs, to: feed, opener: s.chatsOpener) }
            },
            .init("NewTabClosed.wire", needed: "NewTabClosed.wireNeeded") { [weak self] in if let s = self?.services { NewTabClosed.wire(s.agentTabs, services: s) } },
            .init("NewTabPlacesFeed.wire", needed: "NewTabPlacesFeed.wireNeeded") { [weak self] in if let s = self?.services { NewTabPlacesFeed.wire(s.agentTabs, services: s) } },
            .init("NewTabWeather.wire", needed: "NewTabWeather.wireNeeded") { [weak self] in if let s = self?.services { NewTabWeather.wire(s.agentTabs, services: s) } },
        ])
        launchFeeds?.post()
    }
}
