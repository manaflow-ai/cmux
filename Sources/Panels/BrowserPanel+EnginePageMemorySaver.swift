import CmuxBrowser
import Foundation

/// Browser Memory Saver for a panel whose page is not WebKit (Chromium).
///
/// A WebKit panel discards by swapping in a blank web view. A Chromium panel
/// keeps its page: the engine closes the page's renderer and recreates it
/// from the saved history when the panel restores. The discard manager keeps
/// the same bookkeeping (timer, memory budget, pressure, the manual-restore
/// setting), so both engines follow one policy.
extension BrowserPanel {
    /// The panel's non-WebKit page when its engine can release its content.
    var memoryReclaimingEnginePage: (any BrowserPage & BrowserPageMemoryReclaiming)? {
        enginePage as? any BrowserPage & BrowserPageMemoryReclaiming
    }

    /// Releases a hidden non-WebKit page's content once the page says it is
    /// not busy (playing media, edited form fields). The release lands after
    /// the probe, only if the panel is still hidden, still holds that page,
    /// and nothing else came to block it meanwhile.
    /// - Returns: Whether a release was started.
    func releaseEnginePageForMemory(reason: String, now: Date) -> Bool {
        guard let page = memoryReclaimingEnginePage, !page.isContentReleased else { return false }
        let urgency = BrowserHiddenWebViewDiscardUrgency(reason: reason)
        guard enginePageDiscardBlockers(urgency: urgency).isEmpty else { return false }
        // task-owner: one probe per discard request; the page answers or the deadline does.
        Task { @MainActor [weak self, weak page] in
            guard let page else { return }
            let probe = await BrowserPageBusyProbe.run(in: page)
            guard let self, self.enginePage === page, !page.isContentReleased,
                  probe.blockers(underPressure: urgency == .systemMemoryPressure).isEmpty,
                  self.enginePageDiscardBlockers(urgency: urgency).isEmpty,
                  page.releaseContent() else { return }
            self.hiddenWebViewDiscardManager.markDiscarded(reason: reason, now: Date())
            self.refreshWebViewLifecycleState()
#if DEBUG
            cmuxDebugLog("browser.discard.engine released panel=\(self.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        }
        return true
    }

    /// The discard blockers for this panel; the snapshot already leaves out
    /// the WebKit-only checks for an engine page.
    private func enginePageDiscardBlockers(urgency: BrowserHiddenWebViewDiscardUrgency) -> [String] {
        hiddenWebViewDiscardManager.blockers(for: hiddenWebViewDiscardSnapshot, urgency: urgency)
    }

    /// Restores a released non-WebKit page, unless the person restores it by
    /// hand (`browser.autoRestoreUnloadedPages` off) and this is only the pane
    /// being shown.
    /// - Returns: Whether the page was restored.
    func restoreEnginePageIfReleased(reason: String, trigger: DiscardRestoreTrigger) -> Bool {
        guard let page = memoryReclaimingEnginePage, hiddenWebViewDiscardManager.isDiscardedForMemory else { return false }
        if trigger == .paneShown, hiddenWebViewDiscardManager.waitsForManualRestore { return false }
        let restored = hiddenWebViewDiscardManager.reactivateWithoutNavigation(reason: reason) {
            page.restoreContent()
        }
        if restored { refreshWebViewLifecycleState() }
        return restored
    }

    /// The process the memory budget counts for this panel's page: the
    /// engine page's renderer, or nil while its content is released.
    var enginePageContentProcessIdentifier: Int? {
        guard let page = memoryReclaimingEnginePage, !page.isContentReleased else { return nil }
        return page.contentProcessIdentifier
    }
}
