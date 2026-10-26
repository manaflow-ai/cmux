import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CoreGraphics
import Foundation
import Observation

/// Restoring a hibernated page: the `restore` effect recreates its engine page from the saved
/// history, and each wake is timed (`wakeLog`, `debug.surfaces` `wakes`) from the effect to the
/// page being back and to its load ending.
extension BrowserHibernation {
    /// The user navigated, reloaded or went back or forward in a hibernated
    /// page: restore it, then apply that request.
    func wakeForNavigation(_ key: String, _ wake: HibernatedBrowserTab.Wake) {
        guard let cache else { return }
        pendingWakes[key] = wake
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
    }

    /// The user's Wake Tab action (restores in the background).
    func wake(_ key: String) -> Bool {
        guard let cache, cache.lifecycle.phase(key) == .hibernated else { return false }
        cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
        return true
    }

    /// The `restore` effect: recreates the engine page from the saved
    /// history; the lifecycle shows it if it is still selected when it lands.
    func restore(_ key: String, token: ContentLifecycle<String>.Token) {
        guard let cache, let placeholder = cache.browsers[key]?.tab as? HibernatedBrowserTab else {
            cache?.applyLifecycle(cache?.lifecycle.send(.mountFailed(key, token)) ?? [])
            return
        }
        // The record's profile: a tab moved to another one while asleep wakes there, without the old one's history.
        let profile = cache.tabModel(key) == nil ? placeholder.profileID : cache.browserProfile?(key) ?? placeholder.profileID
        let history = profile == placeholder.profileID ? placeholder.restoreState : nil
        wakeLog.start(key, engine: placeholder.engineKind, snapshot: snapshotImage(key) != nil)
        if case .appPage(let saved) = placeholder.restoreState {
            return restoreAppPage(key, saved, token: token)
        }
        var configuration = BrowserTabConfiguration(id: placeholder.id, profile: profile, zoom: placeholder.state.zoom)
        switch placeholder.engineKind {
        case .webkit:
            let tab = cache.webKit.makeWebKitTab(id: configuration.id, profile: configuration.profile, zoom: configuration.zoom)
            if !(history.map({ tab.restore($0) }) ?? false), let url = placeholder.state.url { tab.load(url) }
            finishRestore(key, token: token, page: tab)
        case .cef:
            configuration.initialURL = placeholder.state.url
            configuration.restoreState = history
            let make = cache.makeCEFTab
            let tab = cache.tabModel(key)
            Task { @MainActor [weak self, weak cache] in
                do {
                    // The remote-localhost store and guard, as for any Chromium page.
                    let configured = await cache?.chromiumConfiguration(for: tab, base: configuration) ?? configuration
                    let page = try await make(configured)
                    self?.finishRestore(key, token: token, page: page)
                } catch {
                    guard let cache = self?.cache else { return }
                    self?.logger.error("restore \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    cache.applyLifecycle(cache.lifecycle.send(.mountFailed(key, token)))
                }
            }
        }
    }

    /// A cmux page (`BrowserAppPage`) is built again at its address, as its tab's record opens it,
    /// and gets its view state back.
    private func restoreAppPage(_ key: String, _ saved: BrowserAppPageState, token: ContentLifecycle<String>.Token) {
        guard let cache, let tab = cache.tabModel(key), let page = cache.makeAppPage(saved.url, for: tab) else {
            cache?.applyLifecycle(cache?.lifecycle.send(.mountFailed(key, token)) ?? [])
            return
        }
        (page as? any BrowserAppPage)?.restoreViewState(saved)
        finishRestore(key, token: token, page: page)
    }

    private func finishRestore(_ key: String, token: ContentLifecycle<String>.Token, page: any BrowserTab) {
        guard let cache, let asleep = cache.browsers[key]?.tab as? HibernatedBrowserTab, cache.lifecycle.record(key)?.pending == token else {
            // Closed or superseded while it restored.
            page.close()
            return
        }
        // The new page starts unmuted: a tab muted when it slept wakes muted.
        if asleep.state.isAudioMuted, let muting = page as? BrowserAudioMuting { muting.setAudioMuted(true) }
        // Its last frame stays over the new page until the page paints: no blank frame on a wake.
        // The pixels the placeholder shows now are already decoded, so the cover has them in the
        // swap's own frame. A page that cannot show one (a Chromium page in its own child window) is counted.
        // A native cmux page draws in its first frame and needs none; one in a web engine does. A remote
        // stream connects first: it keeps the picture for a reconnect's cap (`BrowserWakeStandIn.wakeCoverCap`).
        let shown = asleep.shownPicture
        if (page as? any BrowserAppPage)?.drawsInFirstFrame != true, let picture = shown ?? snapshotImage(key) {
            let standIn = page as? any BrowserWakeStandIn
            let covered = standIn?.showStandIn(picture, decoded: shown != nil, cap: standIn?.wakeCoverCap ?? Self.standInCap,
                                               clock: standInClock) ?? false
            if !covered { uncoveredWakes += 1 }
        }
        cache.swapPage(key, with: page, asleep: asleep.state)
        cache.dormantTabs.set(key, false)
        savedBytes[key] = nil
        // The live page now; a later sleep takes a new picture.
        snapshots.remove(key)
        restoredCount += 1
        cache.applyLifecycle(cache.lifecycle.send(.mounted(key, token)))
        if let latency = wakeLog.mounted(key, visible: cache.lifecycle.phase(key) == .mountedVisible) { onWakeMounted(latency) }
        timeLoad(key, page: page)
        // A navigation or history step that woke the page runs once its
        // history is back (a reload just wakes it: restoring loads the page).
        switch pendingWakes.removeValue(forKey: key) {
        case .load(let url)?: page.load(url)
        case .goBack?: page.goBack()
        case .goForward?: page.goForward()
        case .reload?, nil: break
        }
    }

    /// Records when the woken page's load ends (finished or failed), bounded: a page that is
    /// still loading after 15 s records none.
    private func timeLoad(_ key: String, page: any BrowserTab) {
        Task { @MainActor [weak self, weak page] in
            let ended = try? await ControlDeadline.shared.run(method: "hibernation.wake", deadline: .now + .seconds(15)) { @MainActor in
                for await ended in ObservationStream({ page.map { Self.loadEnded($0.state.phase) } ?? true }) where ended { return true }
                return false
            }
            guard let self, let page, self.cache?.browsers[key]?.tab === page else { return }
            self.wakeLog.loaded(key, ended: ended == true)
        }
    }

    private static func loadEnded(_ phase: BrowserLoadPhase) -> Bool {
        switch phase {
        case .finished, .failed: true
        case .idle, .provisional, .committed: false
        }
    }

    /// The picture a hibernated tab shows, compressed or decoded (`HibernationTunables.compressedSnapshots` off).
    func snapshotImage(_ key: String) -> CGImage? {
        snapshots.image(for: key)
    }

    /// Keeps a hibernating page's picture until it wakes or closes.
    func keep(_ picture: HibernationSnapshots.Picture, for key: String) {
        snapshots.insert(picture, for: key)
    }

    /// A fresh picture (never one from an earlier sleep), kept in `snapshots`: compressed whole by
    /// default; with `HibernationTunables.compressedSnapshots` off, decoded and scaled so that four fit
    /// the store. None, and no capture, when the store would not keep it (the critical memory limit, for
    /// a tab beside no shown tab).
    func snapshot(_ tab: any BrowserTab, key: String) async -> HibernationSnapshots.Picture? {
        guard snapshots.keeps(key), let image = await capture(tab) else { return nil }
        if HibernationTunables.compressedSnapshots.value { return await HibernationSnapshots.compress(image) }
        // A quarter of the store, less a margin for row padding; same aspect and color space, off the main actor.
        let bytes = Double(snapshots.fullCapacityBytes / 4) * 0.98
        let scale = min(1, (bytes / Double(max(image.width * image.height * 4, 1))).squareRoot())
        let fitted = await TabPreviewFitting.fit(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
        return HibernationSnapshots.Picture(data: nil, image: fitted)
    }
}

/// One Duration in seconds, fractions included (the hibernation deadlines and their elapsed times,
/// and TopPageHost's hidden times). The one copy in CmuxNextApp: a second, even private, is a redeclaration.
extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
