import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextHibernation
import CmuxNextWakeups
import Foundation

// The page probe of browser hibernation and the facts it adds to (moved from BrowserHibernation.swift).
extension BrowserHibernation {
    /// Asks hidden page `tab` what it does (`PageProbe`). Runs no page code: whether a `beforeunload`
    /// handler would ask is learned only right before a discard (`asksBeforeUnload`). `limit` bounds the answer
    /// (``pageDeadline``).
    static func probe(_ tab: any BrowserTab, within limit: Duration = .seconds(2)) async -> PageProbe {
        // A cmux page or a remote stream runs no site script here and holds no form, media or capture: nothing to ask.
        if tab is any BrowserAppPage || tab is any BrowserStreamedPage { return PageProbe() }
        do {
            let (value, busy) = try await ControlDeadline.shared.run(method: "hibernation.probe", deadline: .now + limit) { @MainActor in
                (try await tab.evaluate(BrowserPageBusy.fieldProbeScript, world: .isolated, gesture: .cmux), try await tab.pageBusy())
            }
            guard case .string(let json) = value, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Bool] else { return unanswered(tab) }
            // Media the tab's mute silences still plays (cx-d0d.24): hibernating would drop the mute.
            let muted = tab.state.isAudioMuted && tab.state.media?.isPlaying == true
            // A video in Picture in Picture plays on in its floating window, paused or muted alike.
            let floating = tab.state.media?.isPictureInPicture == true
            // The recorder knows the person's edits (`BrowserPageBusy`); a page loaded before it compares every field.
            return PageProbe(playingMedia: muted || floating || (object["media"] ?? true), editedForm: busy.editedForm ?? object["form"] ?? true,
                             capturing: busy.capturing, webAudio: busy.audio, beforeUnload: busy.beforeUnload,
                             unloadHandler: busy.unloadHandler, webRTC: busy.webRTC,
                             connectedDevice: busy.connectedDevice, unreadableFrame: busy.unreadableFrame,
                             audible: object["sound"] == true || busy.audio, heldWebLock: busy.webLock, openIndexedDB: busy.indexedDB)
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

    /// The host of the page tab `key` shows (Never Hibernate This Site); nil for none.
    func host(of key: String) -> String? {
        guard let host = cache?.browsers[key]?.tab.state.url?.host(), !host.isEmpty else { return nil }
        return host
    }

    /// An agent called hidden page `key` within `agentGrace` or holds its lease (its next call
    /// would wait on a thaw); what the page shows then is the agent's doing.
    func isAgentDriven(_ key: String) -> Bool {
        if let used = agentUsedAt[key], now() - used < .seconds(Self.agentGrace) { return true }
        return leased.contains(key)
    }

    /// Watches hidden page `key`'s title and icon (`PageActivityWatch`, when on): the first change
    /// of the page's own keeps it from the timeout and from freezing until it shows
    /// (`DiscardRule.backgroundActivity`); an agent's changes do not count.
    func watchActivity(_ key: String, _ tab: any BrowserTab) {
        activity.hide(key, look: { [weak tab] in
            tab.map { PageBackgroundActivity.Look(document: $0.state.documentGeneration, title: $0.state.title, icon: $0.state.faviconURL) }
        }, isAgentDriven: { [weak self] in self?.isAgentDriven(key) ?? false }, onActive: { [weak self] in self?.replan() })
    }

    /// The planner's facts of hidden page `key`, before any probe (`PageProbe.fill(_:)` adds its answer).
    func candidate(_ key: String, entry: BrowserEntry, hiddenFor: Double, now: ContinuousClock.Instant = .now) -> HibernationPlanner.Candidate {
        let tab = entry.tab
        let capturing = (tab as? any PageInfoProviding).map { !$0.pageInfoInUse.union($0.pageInfoActivity.inUse).isEmpty } ?? false
        // A cmux page restores only when `memoryDiscardPageTabs` is on (`discardsAppPages`), a remote stream
        // only when `memoryDiscardRemoteTabs` is (`discardsStreamedPages`).
        // A page whose renderer ended shows the crash notice until the person reloads it: a
        // discard would drop the notice and its restore would load the page by itself.
        let restores = tab.state.processExit == nil
            && (tab as? any BrowserHibernationSource)?.supportsHibernation == true && (discardsAppPages || !(tab is any BrowserAppPage))
            && (discardsStreamedPages || !(tab is any BrowserStreamedPage))
        var candidate = HibernationPlanner.Candidate(
            key: key, hiddenFor: hiddenFor, host: tab.state.url?.host(), isPinned: isPinned(key),
            hasDevTools: (tab as? any BrowserDevToolsHosting)?.devTools.isOpen ?? false, isCapturing: capturing,
            canRestore: restores,
            showsFormSubmission: (tab as? any BrowserHibernationSource)?.showsFormSubmission ?? false
        )
        candidate.recentFocusCount = focusHistory.count(key, now: now)
        candidate.memoryBytes = memoryBytes[key]
        candidate.isDownloading = isDownloading(key)
        candidate.hasAgentLease = leased.contains(key)
        candidate.allowsNotifications = (tab as? any BrowserHibernationSource)?.allowsNotifications ?? false
        candidate.hasBackgroundActivity = activity.contains(key)
        candidate.discardAttempted = discardAttempts.contains(key)
        if let audible {
            // The tab's own media report keeps it with no probe; the end of its sound starts the minute.
            candidate.isAudible = (tab as? any BrowserAudibleReporting)?.isAudible == true
            candidate.secondsSinceAudible = audible.secondsSinceAudible(key)
        }
        return candidate
    }

    /// Page `page` became tab `key`'s page (`TabContentCache.mount`: a new tab, a swap, a restore,
    /// a stand-in's move): with `recentlyAudibleProtection` its sound is followed from now on, shown
    /// or hidden, through its one audible bit (`BrowserAudibleReporting`), as Chrome's page node
    /// follows its audio from creation. A page that plays nothing (a hibernated placeholder, an app
    /// page) drops the old page's watch. A Chromium page follows its tab's node (``followVisibility(_:_:)``) and
    /// reports its crashed subframes (``subframeDidCrash(_:)``).
    func pageDidMount(_ key: String, _ page: any BrowserTab) {
        followVisibility(key, page)
        crashedSubframes[key] = nil
        if discardsCrashedSubframes, let page = page as? any BrowserSubframeCrashReporting {
            page.onSubframeCrash = { [weak self] in self?.subframeDidCrash(key) }
        }
        guard let audible else { return }
        guard let speaker = page as? any BrowserAudibleReporting else { return audible.unwatch(key) }
        audible.watch(key, speaker) { [weak speaker] in speaker?.isAudible == true }
    }

    /// A frame of page `key` crashed in another renderer (``BrowserSubframeCrashReporting``): its document holds a
    /// sad frame until it reloads or navigates. Hidden now or at its next hide, the page is discarded
    /// (``discardCrashedSubframe(_:)``), so it shows again reloaded whole and its renderers' memory goes; a shown
    /// page keeps its sad frame. Chrome's DiscardPageWithCrashedSubframePolicy
    /// (chrome/browser/performance_manager/policies/discard_page_with_crashed_subframe_policy.cc) checks at the
    /// crash and at each visibility change (OnIsVisibleChanged).
    func subframeDidCrash(_ key: String) {
        guard discardsCrashedSubframes, let tab = cache?.browsers[key]?.tab else { return }
        crashedSubframes[key] = tab.state.documentGeneration
        discardCrashedSubframe(key)
    }

    /// Hidden page `key` holds a crashed frame in its current document: it is discarded for
    /// ``DiscardReason/crashedSubframe``, a discard cmux starts, so the probe, the lead rule, `beforeunload` and the
    /// person's choices (`browser.hibernation` off, a pin, Never Hibernate This Site) still keep it.
    func discardCrashedSubframe(_ key: String) {
        guard let crashed = crashedSubframes[key], let cache, let tab = cache.browsers[key]?.tab else { return }
        guard tab.state.documentGeneration == crashed else {
            crashedSubframes[key] = nil
            return
        }
        guard setting.isEnabled, cache.lifecycle.phase(key) == .mountedHidden, !probing.contains(key) else { return }
        cache.trace(key, "discard (\(DiscardReason.crashedSubframe.rawValue))")
        prepare(key, for: .crashedSubframe)
    }

    /// A page's sound ended: a hidden page is planned again, so its minute's end joins the deadline.
    func soundDidEnd(_ key: String) {
        if cache?.lifecycle.phase(key) == .mountedHidden { replan() }
    }

    /// Whether hidden page `key` would ask before it unloads (`BrowserTab.asksBeforeUnload()`): runs
    /// its handlers once per hidden period; a page that asked, or could not be asked, stays.
    func asksBeforeUnload(_ key: String, _ tab: any BrowserTab) async -> Bool {
        if discardAttempts.contains(key) { return true }
        return (try? await ControlDeadline.shared.run(method: "hibernation.beforeunload", deadline: .now + pageDeadline) { @MainActor in
            try await tab.asksBeforeUnload()
        }) ?? true
    }

    /// Hidden page `key`'s discard was tried and did not finish (`why`): it stays until shown
    /// (`DiscardRule.discardAttempted`, Chrome's `DiscardAttemptMarker` of page_discarding_helper.cc), and the
    /// replan gives its slot to the next candidate now.
    func discardFailed(_ key: String, _ why: CannotDiscardReason) {
        discardAttempts.mark(key)
        cache?.trace(key, "discard attempted (\(why.rawValue))")
        replan()
    }
}

// The hidden pages' memory readings: the pressure sample that ranks discards, and the frozen pages'
// growth that discards them with their opener group (`FrozenGrowthRule`, p07-memory.md task 020).
extension BrowserHibernation {
    /// Under memory pressure, samples the tabs' memory when the last sample is stale, then
    /// replans with it (the heaviest of equally idle pages goes first).
    func refreshMemoryIfNeeded() {
        guard pressure != .normal, !memoryReadings.isFresh(at: now()) else { return }
        sampleMemory()
    }

    /// Samples the tabs' memory once, then takes the reading for the frozen pages' growth and
    /// replans. A sample already running gives its reading when it lands.
    private func sampleMemory() {
        guard let measureMemory, memoryReadings.begin() else { return }
        // task-owner: one memory sample; `memoryReadings` admits one at a time
        // main-hop-allow: measureMemory is the app's resource sampler, a main-actor async seam whose process reads run off main; the readings land in its one resume
        Task { @MainActor [weak self] in
            let sample = await measureMemory()
            guard let self else { return }
            self.memoryReadings.land(sample, at: self.now())
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
        growthDeadline.schedule(after: delay) { [weak self] in self?.readFrozenGrowth() }
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
