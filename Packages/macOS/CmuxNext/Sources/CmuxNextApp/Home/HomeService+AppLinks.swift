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

    /// The quit's cache step (`QuitSteps.prepareWindows`, awaited): the coalesced batch and the
    /// write already running reach disk before AppKit's reply, with no thread blocked.
    func flushCache() async {
        await homeStore.flushCache()
    }

    /// Quit and forced exit (`QuitSignal`'s second signal, which calls this and
    /// then `exit`): the links that still point at this app go (another build
    /// that took them over keeps them), and the Home cache writes, on this
    /// thread, whatever is not on disk yet (`HomeStore.flushCacheBeforeExit`):
    /// after the quit's awaited step (``flushCache()``) that is nothing, but a
    /// forced exit can come before that step or during a write.
    func applicationWillTerminate() {
        settleWatch?.cancel()
        homeStore.flushCacheBeforeExit()
        if homeListPrimed { sidebarLaunch.flush() }
        ChiefAppLinks.unpublish(home: chief.home, controlSocket: services.environment.launch.socketPath,
                                daemonSocket: publishedDaemonSocket)
    }
}
