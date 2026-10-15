import CmuxBrowser
import Foundation

/// Browser Memory Saver for a panel whose page is not WebKit (Chromium).
///
/// A WebKit panel discards by swapping in a blank web view. A Chromium panel
/// keeps its page: the engine closes the page's renderer and recreates it
/// from the saved history when the panel restores. The discard manager keeps
/// the same bookkeeping (timer, memory budget, pressure, the manual-restore
/// setting), and a released panel shows the same "unloaded" placeholder, so
/// both engines follow one policy.
extension BrowserPanel {
    /// The panel's non-WebKit page when its engine can release its content.
    var memoryReclaimingEnginePage: (any BrowserPage & BrowserPageMemoryReclaiming)? {
        enginePage as? any BrowserPage & BrowserPageMemoryReclaiming
    }

    /// Releases a hidden non-WebKit page's content once the page says it is
    /// not busy (playing media, edited form fields). The release lands after
    /// the probe, only if the panel is still hidden, still holds that page,
    /// and nothing else came to block it meanwhile. A "busy" answer leaves the
    /// page alone for ``BrowserPageReclaimProbe/busyBackoff``.
    /// - Returns: Whether a release was started.
    func releaseEnginePageForMemory(reason: String, now: Date) -> Bool {
        guard let page = memoryReclaimingEnginePage, !page.isContentReleased,
              page.reclaimProbe.allowsProbe(now: now) else { return false }
        let urgency = BrowserHiddenWebViewDiscardUrgency(reason: reason)
        guard enginePageDiscardBlockers(urgency: urgency).isEmpty else { return false }
        page.reclaimProbe.isRunning = true
        // task-owner: one probe per page at a time; the page answers or the deadline does.
        Task { @MainActor [weak self, weak page] in
            guard let page else { return }
            let probe = await BrowserPageBusyProbe.run(in: page)
            page.reclaimProbe.isRunning = false
            let busy = probe.blockers(underPressure: urgency == .systemMemoryPressure)
            if !busy.isEmpty {
                page.reclaimProbe.busyUntil = Date().addingTimeInterval(BrowserPageReclaimProbe.busyBackoff)
            }
            guard let self, self.enginePage === page, !page.isContentReleased, busy.isEmpty,
                  self.enginePageDiscardBlockers(urgency: urgency).isEmpty,
                  page.releaseContent() else { return }
            self.hiddenWebViewDiscardManager.markDiscarded(reason: reason, now: Date())
            // The pane shows the "unloaded" placeholder, as for a discarded web view.
            self.shouldRenderWebView = false
            self.refreshWebViewLifecycleState()
#if DEBUG
            cmuxDebugLog("browser.discard.engine released panel=\(self.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        }
        return true
    }

    /// Whether the memory budget may count this panel as freeable: a busy
    /// answer or a running probe keeps it out, so the budget moves on to the
    /// next panel instead of planning the same refused release every sample.
    func enginePageAllowsBudgetDiscard(now: Date) -> Bool {
        guard let page = memoryReclaimingEnginePage else { return true }
        return page.reclaimProbe.allowsProbe(now: now)
    }

    /// The discard blockers for this panel; the snapshot already leaves out
    /// the WebKit-only checks for an engine page, and an engine page with its
    /// developer tools open is kept like a WebKit one.
    private func enginePageDiscardBlockers(urgency: BrowserHiddenWebViewDiscardUrgency) -> [String] {
        var blockers = hiddenWebViewDiscardManager.blockers(for: hiddenWebViewDiscardSnapshot, urgency: urgency)
        if enginePage?.isDevToolsVisible == true { blockers.append("developer_tools") }
        return blockers
    }

    /// Restores a released non-WebKit page, unless the person restores it by
    /// hand (`browser.autoRestoreUnloadedPages` off) and this is only the pane
    /// being shown.
    /// - Returns: Whether the page was restored.
    func restoreEnginePageIfReleased(reason: String, trigger: DiscardRestoreTrigger) -> Bool {
        guard let page = memoryReclaimingEnginePage, hiddenWebViewDiscardManager.isDiscardedForMemory else { return false }
        if trigger == .paneShown, hiddenWebViewDiscardManager.waitsForManualRestore { return false }
        let restored = hiddenWebViewDiscardManager.reactivateWithoutNavigation(reason: reason) {
            shouldRenderWebView = true
            page.restoreContent()
        }
        if restored { refreshWebViewLifecycleState() }
        return restored
    }

    /// A released page that came back by itself (a reload, a navigation or a
    /// history step from the chrome or automation) clears the discard state,
    /// so the budget counts it again and the placeholder goes away.
    func noteEnginePageContentRestoredIfLive() {
        guard let page = memoryReclaimingEnginePage, !page.isContentReleased,
              hiddenWebViewDiscardManager.isDiscardedForMemory else { return }
        if hiddenWebViewDiscardManager.reactivateWithoutNavigation(reason: "engine_page_restored", performReactivate: {
            shouldRenderWebView = true
        }) {
            refreshWebViewLifecycleState()
        }
    }

    /// The process the memory budget counts for this panel's page: the
    /// engine page's renderer, or nil while its content is released.
    var enginePageContentProcessIdentifier: Int? {
        guard let page = memoryReclaimingEnginePage, !page.isContentReleased else { return nil }
        return page.contentProcessIdentifier
    }
}
