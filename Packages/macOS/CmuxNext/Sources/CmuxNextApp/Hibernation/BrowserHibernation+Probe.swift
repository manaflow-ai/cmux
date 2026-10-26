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
    /// Under memory pressure, samples the tabs' memory when the last sample is stale, then
    /// replans with it (the heaviest of equally idle pages goes first).
    func refreshMemoryIfNeeded() {
        guard pressure != .normal, let measureMemory, !measuringMemory else { return }
        if let at = memoryMeasuredAt, ContinuousClock.now - at < .seconds(Self.memoryMaxAge) { return }
        sampleMemory(measureMemory)
    }

    /// Samples the tabs' memory once, then takes the reading for the frozen pages' growth and replans.
    private func sampleMemory(_ measureMemory: @escaping () async -> [String: UInt64]) {
        measuringMemory = true
        Task { @MainActor [weak self] in
            let sample = await measureMemory()
            guard let self else { return }
            self.measuringMemory = false
            self.memoryBytes = sample
            self.memoryMeasuredAt = .now
            self.noteFrozenMemory(sample)
            self.replan()
        }
    }

    /// Notes the browser tabs' memory another sampler measured (the Task Manager's samples, the same
    /// estimate as `measureMemory`), so a page discarded while it was open has its number. Only live
    /// pages with a reading count: a closed or sleeping page, or one with nothing measured, keeps
    /// what it had. In Chrome the resource monitor's samples land on the page node, where the
    /// discarder reads them (`PageNodeImpl::EstimatePrivateFootprintSize`).
    func noteMemory(_ bytes: [String: UInt64]) {
        guard let cache else { return }
        for (key, value) in bytes where value > 0 && cache.browsers[key] != nil && !cache.dormantTabs.contains(key) {
            memoryBytes[key] = value
        }
        noteFrozenMemory(bytes)
    }

    // MARK: Frozen growth

    /// Starts the memory readings of page `key`, frozen now. Its reading is the baseline when it is
    /// fresh (within `memoryMaxAge`); otherwise its first reading after the freeze is.
    func trackGrowth(_ key: String) {
        guard discardsGrowingFrozenPages, measureMemory != nil else { return }
        let now = ContinuousClock.now
        let fresh = memoryMeasuredAt.map { now - $0 < .seconds(Self.memoryMaxAge) } ?? false
        frozenGrowth.froze(key, at: now, bytes: fresh ? memoryBytes[key] : nil)
        armGrowthWakeup()
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

    /// The one-shot reading: one sample of every page's memory serves each frozen page due by now.
    private func readFrozenGrowth() {
        frozenGrowth.wake(at: .now)
        armGrowthWakeup()
        // A sample already running gives its reading when it lands.
        guard let measureMemory, !measuringMemory else { return }
        sampleMemory(measureMemory)
    }

    /// A reading of the pages' memory: each frozen page that grew past its threshold goes with the
    /// hidden pages of its opener group; the lead rule still keeps any of them (`FrozenGrowthRule`).
    private func noteFrozenMemory(_ bytes: [String: UInt64]) {
        guard discardsGrowingFrozenPages, let cache else { return }
        let growing = frozenGrowth.record(bytes)
        guard !growing.isEmpty else { return }
        let now = ContinuousClock.now
        var hidden: [String: HibernationPlanner.Candidate] = [:]
        for key in Set(growing.flatMap { openerGroup($0).union([$0]) }) {
            guard cache.lifecycle.phase(key) == .mountedHidden, let at = hiddenAt[key], !probing.contains(key),
                  let entry = cache.browsers[key] else { continue }
            var facts = candidate(key, entry: entry, hiddenFor: (now - at) / .seconds(1), now: now)
            facts.isNeighbor = awakeNeighbors.contains(key) || hoverLeft(key, now: now) != nil
            facts.isAgentDriving = agentUsedAt[key].map { now - $0 < .seconds(Self.agentGrace) } ?? false
            hidden[key] = facts
        }
        let plan = frozenGrowth.plan(growing: growing, groups: openerGroup, candidates: hidden, setting: setting)
        exemptions.merge(plan.exemptions) { $1 }
        for key in plan.due {
            cache.trace(key, "discard (\(DiscardReason.frozenWithGrowingMemory.rawValue))")
            prepare(key, for: .frozenWithGrowingMemory)
        }
    }
}
