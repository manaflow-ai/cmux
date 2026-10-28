import Foundation

/// A tab's Back and Forward entries across the Chromium Host's end (behavior audit 4, P8).
///
/// Chromium keeps a tab's navigation entries in its browser process, and in host mode that process is the
/// Chromium Host: its end takes them, and the remote shim clears its mirror of them before cmux hears the
/// end. So cmux keeps its own copy of the mirrored list at each address change and settled load (fork API
/// 14), and the page the tab loads on the next host gets those entries as its saved history
/// (``BrowserRestoredSession``), as Chrome's session restore gives a crashed browser's tabs their
/// `SerializedNavigationEntry` lists (components/sessions/core/session_service_commands.cc). This holds for an
/// incognito tab too: its entries were only in memory, and cmux's copy outlives the host. Its cookies and site
/// data do not: they were only in the dead host (the crash page says so).
extension CEFTab {
    /// Keeps Chromium's list as the mirror shows it now: one mirror read, no call to Chromium. Host mode only
    /// (in process Chromium ends with cmux), and nothing before fork API 14, which lists no entries.
    func keepNavigationEntries() {
        guard runtime.hostStart != nil, let browserID, let shim = runtime.shim,
              runtime.forkAPIVersion >= Self.backForwardListForkAPI else { return }
        restored.keptNavigationEntries = shim.tabNavigationEntries(browserID)
    }

    /// The host ended with this tab's browser (``hostEnded(_:)``): the list cmux kept, with the entries saved
    /// before a relaunch around it, becomes the session's ``CEFRestoredSession/hostEndHistory``, and Back and
    /// Forward stop offering the dead browser's entries.
    func keepHistoryAcrossHostEnd() {
        let native = restored.keptNavigationEntries.flatMap(CEFNavigationEntries.init(json:)).map { parsed in
            BrowserNavigationList(entries: parsed.entries.map { BrowserNavigationEntry(url: URL(string: $0.url), title: $0.title.isEmpty ? nil : $0.title) },
                                  current: parsed.currentIndex)
        }
        restored.keptNavigationEntries = nil
        if let native, native.entries.count > 1, native.entries.indices.contains(native.current) {
            restored.hostEndHistory = restored.savedSession(around: native)
        }
        nativeHistory = (false, false)
        restored.applyAvailability()
    }

    /// A sad tab's Reload after the host ended loads `url` with the entries the tab had then
    /// (``CEFTab/reload()``): any other load forgets them.
    func loadKeepingHostEndHistory(_ url: URL) {
        let kept = restored.hostEndHistory
        load(url)
        restoreHostEndHistory(kept)
    }

    /// The page `kept` was saved for loads on the next host: its entries become the tab's saved history, so
    /// Back past the new browser's first entry goes to them (``BrowserRestoredSession/restore(_:current:)``).
    func restoreHostEndHistory(_ kept: BrowserSavedSession?) {
        guard let kept, kept.entries.count > 1 else { return }
        restored.restore(kept.entries, current: kept.current)
    }
}
