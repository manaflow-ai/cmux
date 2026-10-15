import CmuxBrowser
import CmuxCEFBrowser
import Foundation

/// A non-WebKit (Chromium) page's permission requests and downloads,
/// answered for its panel (parity row 7).
///
/// Permissions: the policy, then the profile's remembered answers, then the
/// panel's prompt bar (design spec §4). Downloads: staged into WebKit's
/// temporary directory and saved by the same step as WebKit downloads, so
/// the toolbar button, popover, notifications, save panel and REPL sessions
/// behave the same for both engines (design spec §3b).
extension BrowserPanelEnginePageDelegate: BrowserPagePermissionOutcomeDelegate {
    func page(_ page: any BrowserPage, decidePermission request: BrowserPagePermissionRequest) async -> BrowserPagePermissionCoordinator.Outcome {
        await decidePermission(request)
    }

    func pageDidEndPermissionRequest(_ page: any BrowserPage) {
        // Chromium shows one question per page at a time: the bar's is gone.
        permissionQueue.cancelAll()
    }

    /// Decides one permission request of the panel's page.
    func decidePermission(_ request: BrowserPagePermissionRequest) async -> BrowserPagePermissionCoordinator.Outcome {
        guard let panel else { return BrowserPagePermissionCoordinator.Outcome(.prompt) }
        let coordinator = BrowserPagePermissionCoordinator(queue: permissionQueue) { profileID in
            BrowserChromiumProfileEngineStore.current?.sitePermissions.store(forProfileID: profileID)
                ?? BrowserSitePermissionStore(fileURL: nil)
        }
        return await coordinator.decideDetailed(request, profileID: panel.profileID, sessionGrants: sessionGrants(of: panel))
    }

    /// The creating session's grants for a tab a REPL session created (same
    /// as its WebKit tabs), else `nil`.
    private func sessionGrants(of panel: BrowserPanel) -> Set<String>? {
        guard let attachment = BrowserReplTabAttachments.shared.attachment(for: panel.id),
              attachment.appliesSessionPolicies else { return nil }
        return Set(["camera", "microphone", "geolocation", "notifications"].filter { attachment.grants($0) })
    }

    // MARK: Downloads

    /// Chooses a new engine download's temporary file and lists it.
    func stageDownload(_ download: BrowserPageDownload) -> URL? {
        guard let panel, let downloads = panel.downloadDelegate else { return nil }
        let staged = downloadLedger.stage(download)
        downloads.onDownloadStarted?(staged.suggestedFilename, staged.downloadID)
        panel.setRecentDownloadControls(id: staged.downloadID, controls: BrowserDownloadRecord.Controls())
        return staged.temporaryURL
    }

    /// Applies an engine download report (`BrowserPageEvent.downloadUpdated`).
    func applyDownload(_ download: BrowserPageDownload) {
        guard let transition = downloadLedger.apply(download), let panel, let downloads = panel.downloadDelegate else { return }
        switch transition {
        case let .progress(staged, _, _):
            let controls = BrowserDownloadRecord.Controls(isPaused: pausedDownloadIDs.contains(staged.downloadID))
            panel.setRecentDownloadControls(id: staged.downloadID, controls: controls)
        case let .finished(staged):
            pausedDownloadIDs.remove(staged.downloadID)
            panel.setRecentDownloadControls(id: staged.downloadID, controls: nil)
            downloads.finishTemporaryDownload(
                downloadID: staged.downloadID,
                tempURL: staged.temporaryURL,
                suggestedFilename: staged.suggestedFilename,
                sourceURL: staged.sourceURL
            )
        case let .cancelled(staged):
            end(staged)
            downloads.onDownloadCancelled?(staged.suggestedFilename, true, staged.downloadID)
        case let .failed(staged, message):
            end(staged)
            let error = NSError(domain: "cmux.browser.download", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            downloads.onDownloadFailed?(error, true, staged.downloadID)
        }
    }

    /// The page closed: its unfinished downloads end as cancelled.
    func endPageDownloads() {
        permissionQueue.cancelAll()
        let downloads = panel?.downloadDelegate
        for staged in downloadLedger.drain() {
            end(staged)
            downloads?.onDownloadCancelled?(staged.suggestedFilename, true, staged.downloadID)
        }
    }

    /// Pauses or resumes a running engine download from its row.
    func togglePause(_ record: BrowserDownloadRecord) {
        guard let staged = downloadLedger.stagedDownload(downloadID: record.id),
              let page = panel?.enginePage as? CEFBrowserPage else { return }
        let pause = !pausedDownloadIDs.contains(record.id)
        guard page.controlDownload(id: staged.engineDownloadID, action: pause ? 1 : 2) else { return }
        if pause { pausedDownloadIDs.insert(record.id) } else { pausedDownloadIDs.remove(record.id) }
        panel?.setRecentDownloadControls(id: record.id, controls: BrowserDownloadRecord.Controls(isPaused: pause))
    }

    /// Cancels a running engine download from its row; the engine's report ends it.
    func cancel(_ record: BrowserDownloadRecord) {
        guard let staged = downloadLedger.stagedDownload(downloadID: record.id),
              let page = panel?.enginePage as? CEFBrowserPage else { return }
        page.controlDownload(id: staged.engineDownloadID, action: 0)
    }

    private func end(_ staged: BrowserPageDownloadLedger.Staged) {
        pausedDownloadIDs.remove(staged.downloadID)
        panel?.setRecentDownloadControls(id: staged.downloadID, controls: nil)
        let file = staged.temporaryURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
