import AppKit
import CmuxNextHomeEngine
import Foundation

extension HomeService {
    /// Points the Chief home's links at this app (ChiefAppLinks): on Home
    /// open and whenever the app becomes active after Home opened.
    func publishAppLinks() {
        let home = chief.home
        let control = services.environment.launch.socketPath
        let local = services.machines.local.connection
        // task-owner: one endpoint read, then two link renames; ends at once
        Task { [weak self] in
            let daemon = await local?.endpoint?.socketPath
            ChiefAppLinks.publish(home: home, controlSocket: control, daemonSocket: daemon)
            self?.publishedDaemonSocket = daemon ?? self?.publishedDaemonSocket
        }
    }

    /// Republishes the links when this app becomes active again.
    func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            // task-owner: one hop to the main actor per activation
            Task { @MainActor [weak self] in
                guard let self, self.homeOpened else { return }
                self.publishAppLinks()
                self.requests.refresh()
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
