import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextWakeups
import Foundation

// The page probe of browser hibernation and the facts it adds to (moved from BrowserHibernation.swift).
extension BrowserHibernation {
    /// Asks hidden page `tab` what it does (`PageProbe`). Runs no page code: whether a `beforeunload`
    /// handler would ask is learned only right before a discard (`asksBeforeUnload`).
    static func probe(_ tab: any BrowserTab) async -> PageProbe {
        do {
            let (value, busy) = try await ControlDeadline.shared.run(method: "hibernation.probe", deadline: .now + .seconds(2)) { @MainActor in
                (try await tab.evaluate(BrowserPageBusy.fieldProbeScript, world: .isolated, gesture: .cmux), try await tab.pageBusy())
            }
            guard case .string(let json) = value, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return unanswered(tab) }
            // Media the tab's mute silences still plays (cx-d0d.24): hibernating would drop the mute.
            let muted = tab.state.isAudioMuted && tab.state.media?.isPlaying == true
            // A video in Picture in Picture plays on in its floating window, paused or muted alike.
            let floating = tab.state.media?.isPictureInPicture == true
            // The recorder knows the person's edits (`BrowserPageBusy`); a page loaded before it compares every field.
            return PageProbe(playingMedia: muted || floating || (object["media"] ?? true), editedForm: busy.editedForm ?? object["form"] ?? true,
                             capturing: busy.capturing, webAudio: busy.audio, beforeUnload: busy.beforeUnload,
                             unloadHandler: busy.unloadHandler, webRTC: busy.webRTC,
                             connectedDevice: busy.connectedDevice, unreadableFrame: busy.unreadableFrame)
        } catch {
            return unanswered(tab)
        }
    }

    /// A page that did not answer. It used to count as playing, so a page too busy to answer
    /// never froze and was asked again every `freezeSeconds` (the hottest renderer in the
    /// 2026-10-21 audit: 25 % CPU, 586 MB). The media the tab last reported still keeps it: the
    /// page's media script pushes that state (`BrowserMediaState+Scripts`), with no round trip.
    /// WebKit's own camera and microphone state is the planner's `isCapturing`; Chromium reports none to the app.
    static func unanswered(_ tab: any BrowserTab) -> PageProbe {
        let media = tab.state.media
        let playing = media.map { $0.isAudible || ($0.isPlaying && tab.state.isAudioMuted) || $0.isPictureInPicture } ?? false
        return PageProbe(playingMedia: playing, answered: false)
    }

    /// The planner's facts of hidden page `key`, before any probe (`PageProbe.fill(_:)` adds its answer).
    func candidate(_ key: String, entry: BrowserEntry, hiddenFor: Double, now: ContinuousClock.Instant = .now) -> HibernationPlanner.Candidate {
        let tab = entry.tab
        let capturing = (tab as? any PageInfoProviding).map { !$0.pageInfoInUse.union($0.pageInfoActivity.inUse).isEmpty } ?? false
        var candidate = HibernationPlanner.Candidate(
            key: key, hiddenFor: hiddenFor, host: tab.state.url?.host(), isPinned: isPinned(key),
            hasDevTools: (tab as? any BrowserDevToolsHosting)?.devTools.isOpen ?? false, isCapturing: capturing,
            canRestore: (tab as? any BrowserHibernationSource)?.supportsHibernation ?? false,
            showsFormSubmission: (tab as? any BrowserHibernationSource)?.showsFormSubmission ?? false
        )
        candidate.recentFocusCount = recentFocusCount(key, now: now)
        candidate.memoryBytes = memoryBytes[key]
        candidate.isDownloading = isDownloading(key)
        candidate.hasAgentLease = leased.contains(key)
        candidate.allowsNotifications = (tab as? any BrowserHibernationSource)?.allowsNotifications ?? false
        return candidate
    }

    /// Whether hidden page `key` would ask before it unloads (`BrowserTab.asksBeforeUnload()`): runs
    /// its handlers once per hidden period; a page that asked, or could not be asked, stays.
    func asksBeforeUnload(_ key: String, _ tab: any BrowserTab) async -> Bool {
        if askedBeforeUnload.contains(key) { return true }
        let asks = (try? await ControlDeadline.shared.run(method: "hibernation.beforeunload", deadline: .now + .seconds(2)) { @MainActor in
            try await tab.asksBeforeUnload()
        }) ?? true
        if asks { askedBeforeUnload.insert(key) }
        return asks
    }
}

// The hidden pages' memory readings: the pressure sample that ranks discards, and the frozen pages'
// growth that discards them with their opener group (`FrozenGrowthRule`, p07-memory.md task 020).
extension BrowserHibernation {
    /// The host of the page tab `key` shows (Never Hibernate This Site); nil for none.
    func host(of key: String) -> String? {
        guard let host = cache?.browsers[key]?.tab.state.url?.host(), !host.isEmpty else { return nil }
        return host
    }

    /// Under memory pressure, samples the tabs' memory when the last sample is stale, then
    /// replans with it (the heaviest of equally idle pages goes first).
    func refreshMemoryIfNeeded() {
        guard pressure != .normal, !memoryReadings.isFresh(at: .now) else { return }
        sampleMemory()
    }

    /// Samples the tabs' memory once, then takes the reading for the frozen pages' growth and
    /// replans. A sample already running gives its reading when it lands.
    private func sampleMemory() {
        guard let measureMemory, memoryReadings.begin() else { return }
        Task { @MainActor [weak self] in
            let sample = await measureMemory()
            guard let self else { return }
            self.memoryReadings.land(sample, at: .now)
            self.noteFrozenMemory(sample)
            self.replan()
        }
    }

    /// Notes the browser tabs' memory another sampler measured (the Task Manager's samples, the same
    /// estimate as `measureMemory`), so a page discarded while it was open has its number. Only live
    /// pages with a reading count: a closed or sleeping page, or one with nothing measured, keeps
    /// what it had. In Chrome the resource monitor's samples land on the page node, where the
    /// discarder reads them (`PageNodeImpl::EstimatePrivateFootprintSize`).
    func noteMemory(_ readings: [String: PageMemoryReading]) {
        guard let cache else { return }
        memoryReadings.note(readings, at: .now) { cache.browsers[$0] != nil && !cache.dormantTabs.contains($0) }
        noteFrozenMemory(readings)
    }

    // MARK: Frozen growth

    /// Starts the memory readings of page `key`, frozen now. A fresh reading of it
    /// (`PageMemoryReadings.maxAge`) is its baseline; without one, the freeze takes a sample
    /// (once, an event, not a period) and its first reading after the freeze is.
    func trackGrowth(_ key: String) {
        guard discardsGrowingFrozenPages, setting.isEnabled, measureMemory != nil else { return }
        let now = ContinuousClock.now
        let reading = memoryReadings.isFresh(at: now) ? memoryReadings.reading(key) : nil
        frozenGrowth.froze(key, at: now, reading: reading)
        if reading == nil { sampleMemory() }
        armGrowthWakeup()
    }

    /// `browser.hibernation` turned off: no frozen page is read again.
    func stopGrowthReadings() {
        frozenGrowth.removeAll()
        growthDeadline.cancel()
    }

    /// Page `key` thawed (or closed): its readings end, and with them its one-shot wakeups.
    func untrackGrowth(_ key: String) {
        guard frozenGrowth.pages[key] != nil else { return }
        frozenGrowth.thawed(key)
        armGrowthWakeup()
    }

    /// Arms the one deadline of the frozen pages' next one-shot reading, or drops it when none is left.
    private func armGrowthWakeup() {
        guard let next = frozenGrowth.nextWakeup else {
            growthDeadline.cancel()
            return
        }
        let delay = max(next - ContinuousClock.now, .zero) + .milliseconds(50)
        growthDeadline.schedule(after: delay) { @MainActor [weak self] in self?.readFrozenGrowth() }
    }

    /// The one-shot reading due at `now` (its deadline's): one sample of every page's memory serves
    /// each frozen page due by then.
    func readFrozenGrowth(at now: ContinuousClock.Instant = .now) {
        frozenGrowth.wake(at: now)
        armGrowthWakeup()
        sampleMemory()
    }

    /// A reading of the pages' memory: each frozen page that grew past its threshold goes with the
    /// frozen hidden pages of its opener group (`discardGrowing`).
    private func noteFrozenMemory(_ readings: [String: PageMemoryReading]) {
        guard discardsGrowingFrozenPages, setting.isEnabled, !frozenGrowth.pages.isEmpty else { return }
        let growing = frozenGrowth.record(readings)
        if !growing.isEmpty { discardGrowing(growing) }
    }
}
