import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextWakeups
import CoreGraphics
import Foundation

/// Restoring a hibernated page: the `restore` effect recreates its engine page from the saved
/// history, and each wake is timed (`wakeLog`, `debug.surfaces` `wakes`) from the effect to the
/// page being back and to its load ending. A wake nobody asked for goes through ``WakeAdmission``.
extension BrowserHibernation {
    /// A navigation, reload or history step reached a hibernated page: restore it, then apply that
    /// request. A shown page is already restoring, so a hibernated one is a hidden tab an agent or a
    /// script drives; a deferred wake keeps the step for the tab's next show.
    func wakeForNavigation(_ key: String, _ wake: HibernatedBrowserTab.Wake) {
        guard cache != nil else { return }
        pendingWakes[key] = wake
        self.wake(key, by: .automation)
    }

    /// The Wake Tab action (restores in the background): a person's run (`origin` `.user`) restores now; a
    /// run from the CLI, MCP, a script, a page or another client is an agent's wake, admitted by ``admission``.
    func wake(_ key: String, origin: ActionOrigin) -> WakeAdmission.Outcome {
        wake(key, by: origin == .user ? .person : .automation)
    }

    /// Asks to wake hibernated tab `key` for `requester`: a person's wake restores now; an agent's,
    /// a script's or a prewarm's restores when ``admission`` lets it.
    @discardableResult
    func wake(_ key: String, by requester: WakeAdmission.Requester) -> WakeAdmission.Outcome {
        guard let cache else { return .notHibernated }
        guard cache.lifecycle.phase(key) == .hibernated else {
            // It woke another way (a person's show) or closed: a deferral no longer holds it back.
            admission.leftHibernation(key)
            return .notHibernated
        }
        let outcome = admission.request(key, by: requester, pressure: pressure)
        switch outcome {
        case .started: cache.applyLifecycle(cache.lifecycle.send(.wake(key)))
        case .queued: cache.trace(key, "wake queued (\(requester.rawValue))")
        case .deferred(let reason): cache.trace(key, "wake deferred (\(reason.rawValue))")
        case .notHibernated: break
        }
        return outcome
    }

    /// Starts the waiting wakes a pump admitted and traces the ones it dropped.
    func admitted(_ pump: WakeAdmission.Pump) {
        guard let cache else { return }
        for (key, reason) in pump.deferred { cache.trace(key, "wake deferred (\(reason.rawValue))") }
        for entry in pump.starts {
            // The pump skipped tabs that woke another way; one that did since frees its slot again.
            guard cache.lifecycle.phase(entry.key) == .hibernated else {
                restoreEnded(entry.key)
                continue
            }
            cache.applyLifecycle(cache.lifecycle.send(.wake(entry.key)))
            if entry.requester == .prewarm { prewarmedCount += 1 }
        }
    }

    /// Tab `key`'s wake ended (its restore failed or was superseded, or its page's load ended or ran 15 s):
    /// its admission slot goes to the next waiting wake.
    func restoreEnded(_ key: String) {
        admitted(admission.finished(key, pressure: pressure) { self.cache?.lifecycle.phase($0) == .hibernated })
    }

    /// Tab `key` closed: its admission slot, place and deferral go.
    func forgetWake(_ key: String) {
        admission.leftHibernation(key)
        restoreEnded(key)
    }

    /// Why tab `key`'s last wake nobody asked for did not start, while the tab is still hibernated; nil once
    /// it restores or is live by any path (a person's show restores it with no admission request).
    func deferral(of key: String) -> WakeAdmission.Deferral? {
        // The deferral is read first, so a wait on this condition observes its change.
        guard let deferral = admission.deferral(of: key), cache?.lifecycle.phase(key) == .hibernated else { return nil }
        return deferral
    }

    /// The `restore` effect: recreates the engine page from the saved
    /// history; the lifecycle shows it if it is still selected when it lands.
    func restore(_ key: String, token: ContentLifecycle<String>.Token) {
        // Every path out of hibernation comes here; a person's show sends no admission request.
        admission.leftHibernation(key)
        guard let cache, let placeholder = cache.browsers[key]?.tab as? HibernatedBrowserTab else {
            cache?.applyLifecycle(cache?.lifecycle.send(.mountFailed(key, token)) ?? [])
            restoreEnded(key)
            return
        }
        // The record's profile: a tab moved to another one while asleep wakes there, without the old one's history.
        let profile = cache.tabModel(key) == nil ? placeholder.profileID : cache.browserProfile?(key) ?? placeholder.profileID
        let history = profile == placeholder.profileID ? placeholder.restoreState : nil
        wakeLog.start(key, engine: placeholder.engineKind, snapshot: snapshotImage(key) != nil)
        if case .appPage(let saved) = placeholder.restoreState {
            return restoreAppPage(key, saved, token: token)
        }
        var configuration = BrowserTabConfiguration(id: placeholder.id, profile: profile, zoom: placeholder.state.zoom, origin: .user)
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
            // task-owner: one page restore; the lifecycle's token drops a restore that lands after a close or a newer wake
            // main-hop-allow: the cache's Chromium configuration and page make are main-actor async; the restore finishes in their resume
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
                    self?.restoreEnded(key)
                }
            }
        }
    }

    /// A cmux page (`BrowserAppPage`) is built again at its address, as its tab's record opens it,
    /// and gets its view state back.
    private func restoreAppPage(_ key: String, _ saved: BrowserAppPageState, token: ContentLifecycle<String>.Token) {
        guard let cache, let tab = cache.tabModel(key), let page = cache.makeAppPage(saved.url, for: tab) else {
            cache?.applyLifecycle(cache?.lifecycle.send(.mountFailed(key, token)) ?? [])
            restoreEnded(key)
            return
        }
        (page as? any BrowserAppPage)?.restoreViewState(saved)
        finishRestore(key, token: token, page: page)
    }

    private func finishRestore(_ key: String, token: ContentLifecycle<String>.Token, page: any BrowserTab) {
        // An intent prewarm's kinds: the page lays out hidden at its target size, and its cover needs no decode.
        let prewarmed = prewarmKinds.takeForRestore(key)
        if let size = prewarmed.size, page.contentView.window == nil { page.contentView.setFrameSize(size) }
        guard let cache, let asleep = cache.browsers[key]?.tab as? HibernatedBrowserTab, cache.lifecycle.record(key)?.pending == token else {
            // Closed or superseded while it restored.
            page.close()
            restoreEnded(key)
            return
        }
        // The new page starts unmuted: a tab muted when it slept wakes muted.
        if asleep.state.isAudioMuted, let muting = page as? BrowserAudioMuting { muting.setAudioMuted(true) }
        // Its last frame stays over the new page until the page paints: no blank frame on a wake.
        // The pixels the placeholder shows now are already decoded, so the cover has them in the
        // swap's own frame. A page that cannot show one (a Chromium page in its own child window) is counted.
        // A native cmux page draws in its first frame and needs none; one in a web engine does. A remote
        // stream connects first: it keeps the picture for a reconnect's cap (`BrowserWakeStandIn.wakeCoverCap`).
        let shown = asleep.shownPicture ?? prewarmed.cover
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
        noteDiscard(.woke(key))
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
    /// still loading after 15 s records none. R-wait: an engine page's keyed phase wait (`PageWaiters`), read
    /// only on a load-phase change; any other page (a streamed or a cmux page) through an ``ObservedCondition``
    /// on its phase, with a `MainDeadline` for the bound. The end's time is read where the wait returns, so the
    /// record's background task adds no queue time to `loaded_ms`. The load's end (or the bound) also ends
    /// the wake's admission slot, as Chrome counts a background tab as loading until its load ends.
    func timeLoad(_ key: String, page: any BrowserTab) {
        let mainWork = mainWork, deadlines = mainDeadlines, limit = Self.loadTimingLimit
        let waiting = page as? any BrowserPageWaiting
        let condition = waiting == nil ? ObservedCondition(owner: "BrowserHibernation.wakeLoad", .background, on: mainWork) : nil
        // task-owner: one load timing, bounded by 15 s; an engine page's close ends its keyed wait at once
        Task { @concurrent [weak self, weak page] in
            // nil: the condition ended, at the load's end or at the bound; the record reads which from the phase.
            var ended: Bool?
            if let waiting {
                ended = await waiting.when(phase: { phase in BrowserHibernation.loadEnded(phase) }, timeout: limit) != nil
            } else {
                await condition?.until(timeout: limit, deadlines: deadlines) { [weak page] in
                    page.map { BrowserHibernation.loadEnded($0.state.phase) } ?? true
                }
            }
            let at = ContinuousClock.now, result = ended
            await mainWork.apply(.background, owner: "BrowserHibernation.wakeLoaded") { [weak self, weak page] in
                self?.restoreEnded(key)
                guard let self, let page, cache?.browsers[key]?.tab === page else { return }
                wakeLog.loaded(key, ended: result ?? Self.loadEnded(page.state.phase), at: at)
            }
        }
    }

    /// How long a woken page's load is timed before it records none.
    nonisolated static let loadTimingLimit: Duration = .seconds(15)

    private nonisolated static func loadEnded(_ phase: BrowserLoadPhase) -> Bool {
        switch phase {
        case .finished, .failed: true
        case .idle, .provisional, .committed: false
        }
    }

    /// The picture a hibernated tab shows, compressed or decoded (feature `compressedSnapshots` off).
    func snapshotImage(_ key: String) -> CGImage? {
        snapshots.image(for: key)
    }

    /// Keeps a hibernating page's picture until it wakes or closes.
    func keep(_ picture: PurgeablePicture, for key: String) {
        snapshots.insert(picture, for: key)
    }

    /// A fresh picture (never one from an earlier sleep), kept in `snapshots`: compressed whole by
    /// default; with feature `compressedSnapshots` off (`snapshots.keepsCompressed`), decoded and
    /// scaled so that four fit the store. None, and no capture, when the store would not keep it (the
    /// critical memory limit, for a tab beside no shown tab).
    func snapshot(_ tab: any BrowserTab, key: String) async -> PurgeablePicture? {
        guard snapshots.keeps(key), let image = await capture(tab) else { return nil }
        if snapshots.keepsCompressed { return await HibernationSnapshots.compress(image, allocator: snapshots.allocator) }
        // A quarter of the store, less a margin for row padding; same aspect and color space, off the main actor.
        let bytes = Double(snapshots.fullCapacityBytes / 4) * 0.98
        let scale = min(1, (bytes / Double(max(image.width * image.height * 4, 1))).squareRoot())
        let fitted = await TabPreviewFitting.fit(image, CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
        return await HibernationSnapshots.decoded(fitted, allocator: snapshots.allocator)
    }
}

/// The intent prewarm's warmer: a frozen or hibernated hidden page is cold. Its prewarm
/// fits a frozen page to its target size and thaws it; for a hibernated page it records the target size,
/// decodes its cover off the main thread, then restores it hidden (`warm`) with both
/// (``IntentPrewarmKinds``). A prewarm adds no hold, so a cancelled one drops its kinds and plans again:
/// the page sleeps by the normal rules.
extension BrowserHibernation: IntentPrewarmWarming {
    /// Wakes a hidden page early (a neighbor, a hovered tab, an intent prewarm): thaws a frozen one,
    /// restores a hibernated one in the background (the lifecycle keeps it hidden until selected).
    /// `requester` is `.person` for a press on its row, which commits on its release.
    func warm(_ key: String, by requester: WakeAdmission.Requester = .prewarm) {
        guard let cache else { return }
        thaw(key, prewarm: true)
        guard wake(key, by: requester) == .started else { return }
        prewarmedCount += 1
        cache.trace(key, "prewarmed (restore)")
    }

    func isCold(_ key: String) -> Bool {
        guard let cache, cache.browsers[key] != nil else { return false }
        return frozen.contains(key) || cache.lifecycle.phase(key) == .hibernated
    }

    func startPrewarm(_ key: String, trigger: IntentPrewarmTrigger) {
        cache?.trace(key, "intent prewarm (\(trigger.rawValue))")
        let size = prewarmTargetSize(key)
        // A press on a row is the person's; a hover dwell or a key step guesses the next tab.
        let requester: WakeAdmission.Requester = trigger == .pointerDown ? .person : .prewarm
        guard cache?.lifecycle.phase(key) == .hibernated else {
            warm(key, by: requester)
            if let size, let view = cache?.browsers[key]?.tab.contentView, view.window == nil { view.setFrameSize(size) }
            return
        }
        prewarmKinds.target(key, size: size)
        // A decode already running restores the page when it lands.
        guard prewarmKinds.decodes[key] == nil else { return }
        guard let decodeCover = prewarmKinds.decodeCover, let picture = snapshotImage(key) else { return warm(key, by: requester) }
        let ticket = prewarmKinds.beginDecode(key)
        decodeCover(picture) { [weak self] cover in self?.coverDecoded(key, cover, ticket: ticket, by: requester) }
    }

    func cancelPrewarm(_ key: String) {
        prewarmKinds.cancel(key)
        admission.cancelPrewarm(key)
        replan()
    }

    /// A prewarm's cover is decoded: the hidden restore starts with it, unless the page woke another way meanwhile.
    private func coverDecoded(_ key: String, _ cover: CGImage, ticket: UInt64, by requester: WakeAdmission.Requester) {
        guard prewarmKinds.decoded(key, cover, ticket: ticket) else { return } // cancelled meanwhile
        guard cache?.lifecycle.phase(key) == .hibernated else { return prewarmKinds.cancel(key) }
        warm(key, by: requester)
    }

    /// The size `key`'s page shows at: the content size of the pane whose strip lists it, else its view's size when it slept.
    private func prewarmTargetSize(_ key: String) -> CGSize? {
        if let pane = neighbors.pane(listing: key), let size = cache?.presenters[pane]?.value?.presentedContentSize,
           size.width > 0, size.height > 0 { return size }
        return prewarmKinds.sleptSizes[key]
    }

    /// Hidden page `key` froze: a prewarm held for it is spent, so the next press on its row prewarms it again.
    func noteFrozen(_ key: String) {
        intentPrewarm?.service.cooled(key)
        cache?.trace(key, "frozen")
    }

    /// Hidden page `key` hibernates with its view at `size`: its picture (if any) is kept, a prewarm held for it
    /// is spent, and `size` is its target size until a pane lists it.
    func keepAsleep(_ key: String, picture: PurgeablePicture?, size: CGSize) {
        if let picture { keep(picture, for: key) }
        intentPrewarm?.service.cooled(key)
        prewarmKinds.slept(key, size: size)
    }

    /// Tab `key` closed: it leaves the prewarm FIFO and its kinds go.
    func forgetPrewarm(_ key: String) {
        intentPrewarm?.service.forget(key)
        prewarmKinds.forget(key)
    }
}

/// One Duration in seconds, fractions included (the hibernation deadlines and their elapsed times,
/// and TopPageHost's hidden times). The one copy in CmuxNextApp: a second, even private, is a redeclaration.
extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
