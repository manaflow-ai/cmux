import AppKit
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation

extension HomeService {
    /// Points the Chief home's links at this app (ChiefAppLinks): on Home
    /// open and whenever the app becomes active after Home opened. The
    /// endpoint read and the link renames run off the main actor; the
    /// published socket comes back as background work (recipe R-hop).
    func publishAppLinks() {
        let home = chief.home
        let control = services.environment.launch.socketPath
        let local = services.machines.local.connection
        let work = services.work, mainWork = services.mainWork
        // task-owner: one endpoint read, then two link renames on the files lane; ends with them
        work.task(.bestEffort) { [weak self] in
            let daemon = await local?.endpoint?.socketPath
            try await work.run(.bestEffort, mayBlock: .files) {
                ChiefAppLinks.publish(home: home, controlSocket: control, daemonSocket: daemon)
            }
            mainWork.postFromAnyThread(.background, owner: "HomeService.appLinks") { [weak self] in
                guard let self else { return }
                publishedDaemonSocket = daemon ?? publishedDaemonSocket
            }
        }
    }

    /// Republishes the links when this app becomes active again: one app-wide notice subscription
    /// (`AppEvents`), and the work is posted in the background class.
    func observeActivation() {
        guard activationObserver == nil else { return }
        let mainWork = services.mainWork
        // raw-observer-allow: this is the AppEvents subscription recipe R-notif asks for (the app's one observer); only the notice's name matches
        activationObserver = services.appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "HomeService.appLinks") { [weak self] in
            mainWork.post(.background, owner: "HomeService.appLinks") { [weak self] in
                guard let self, homeOpened else { return }
                publishAppLinks()
                requests.refresh()
            }
        }
    }

    /// Quit's save step: the Home cache's last batch reaches disk (written on the cache actor;
    /// the quit only waits), before the process can end.
    func flushCacheForQuit() async {
        await homeStore.flushCache()
    }

    /// Quit: the links that still point at this app go (another build that took them over keeps
    /// them). The cache was written by the quit's save step (``flushCacheForQuit()``).
    func applicationWillTerminate() {
        settleWatch?.cancel()
        if homeListPrimed { sidebarLaunch.flush() }
        ChiefAppLinks.unpublish(home: chief.home, controlSocket: services.environment.launch.socketPath,
                                daemonSocket: publishedDaemonSocket)
    }
}
