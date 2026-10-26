import CmuxNextBrowser
import CmuxNextControl
import CmuxNextHibernation
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
                             connectedDevice: busy.connectedDevice, unreadableFrame: busy.unreadableFrame,
                             audible: object["sound"] == true || busy.audio)
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
        if let used = agentUsedAt[key], ContinuousClock.now - used < .seconds(Self.agentGrace) { return true }
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
        candidate.hasBackgroundActivity = activity.contains(key)
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
    /// page) drops the old page's watch.
    func pageDidMount(_ key: String, _ page: any BrowserTab) {
        guard let audible else { return }
        guard let speaker = page as? any BrowserAudibleReporting else { return audible.unwatch(key) }
        audible.watch(key, speaker) { [weak speaker] in speaker?.isAudible == true }
    }

    /// A page's sound ended: a hidden page is planned again, so its minute's end joins the deadline.
    func soundDidEnd(_ key: String) {
        if cache?.lifecycle.phase(key) == .mountedHidden { replan() }
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
