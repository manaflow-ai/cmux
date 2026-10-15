import CmuxBrowser
import CmuxCEF
import Foundation

/// A Chromium page's permission prompts and downloads, answered through the
/// page's UI delegate (the browser panel).
///
/// Permissions: Chromium's own bubble anchors to a toolbar cmux never shows,
/// so every request is answered here. A grant accepts, a deny denies, and no
/// answer leaves the request waiting until Chromium ends it (never a
/// dismissal, which Chromium counts toward blocking the site for days). A
/// one-time grant is accepted and then reset to "ask" in Chromium's content
/// settings, which save every accepted prompt.
///
/// Downloads: the delegate chooses each download's file (nil cancels), and
/// the page reports progress and the end as ``BrowserPageEvent/downloadUpdated(_:)``.
@MainActor
final class CEFBrowserPageDataBridge {
    /// Permission prompts Chromium still waits on, by fork token.
    private var waitingPermissions: Set<Int32> = []
    /// Running downloads, by shim token.
    private var downloads: [Int32: BrowserPageDownload] = [:]
    /// Downloads waiting for their file, by shim token.
    private var choosing: Set<Int32> = []

    private var runtime: CEFRuntime { .shared }

    func handle(_ event: CEFShimEvent, page: CEFBrowserPage) {
        switch event {
        case let .permissionPrompt(_, token, permissions, origin):
            askPermission(token: token, bits: permissions, origin: origin, page: page)
        case let .permissionDismissed(_, token):
            guard waitingPermissions.remove(token) != nil else { return }
            (page.uiDelegate as? any BrowserPagePermissionOutcomeDelegate)?.pageDidEndPermissionRequest(page)
        case let .download(kind, browser, token, a, b, s1, s2):
            guard let download = BrowserChromiumDownloadEvent(kind: kind, browser: browser, token: token, a: a, b: b, s1: s1, s2: s2) else {
                return
            }
            handle(download, page: page)
        default:
            break
        }
    }

    // MARK: Permissions

    private func askPermission(token: Int32, bits: Int64, origin: String, page: CEFBrowserPage) {
        let request = BrowserChromiumPermissionRequest(cefPromptBits: UInt32(truncatingIfNeeded: bits))
        let pageRequest = request.pageRequest(origin: URL(string: origin))
        waitingPermissions.insert(token)
        let delegate = page.uiDelegate
        Task { @MainActor [weak self, weak page] in
            guard let page else { return }
            let outcome: BrowserPagePermissionCoordinator.Outcome
            if let delegate = delegate as? any BrowserPagePermissionOutcomeDelegate {
                outcome = await delegate.page(page, decidePermission: pageRequest)
            } else if let delegate {
                outcome = BrowserPagePermissionCoordinator.Outcome(await delegate.page(page, requestPermission: pageRequest))
            } else {
                // No panel to ask: no answer (never a saved deny).
                outcome = BrowserPagePermissionCoordinator.Outcome(.prompt)
            }
            // Chromium ended the question meanwhile: nothing to answer.
            guard let self, self.waitingPermissions.remove(token) != nil else { return }
            self.answer(token: token, outcome: outcome, kinds: pageRequest.kinds, origin: origin, page: page)
        }
    }

    private func answer(
        token: Int32,
        outcome: BrowserPagePermissionCoordinator.Outcome,
        kinds: [BrowserPagePermissionRequest.Kind],
        origin: String,
        page: CEFBrowserPage
    ) {
        switch outcome.decision {
        case .grant:
            runtime.answerPermission(token: token, allow: true)
            guard outcome.isOneTime, let browserID = page.browser.browserID else { return }
            for kind in kinds {
                guard let type = BrowserChromiumPermissionRequest.contentSettingType(for: kind) else { continue }
                runtime.setContentSetting(
                    browser: browserID, origin: origin, type: type,
                    value: BrowserChromiumPermissionRequest.contentSettingDefault
                )
            }
        case .deny:
            runtime.answerPermission(token: token, allow: false)
        case .prompt:
            break
        }
    }

    // MARK: Downloads

    private func handle(_ event: BrowserChromiumDownloadEvent, page: CEFBrowserPage) {
        switch event {
        case let .started(token, _, url, suggestedName, totalBytes):
            if let running = downloads[token], let destination = running.destination {
                // Chromium resuming an interrupted download asks again: same file.
                runtime.continueDownload(token: token, to: destination.path)
                return
            }
            guard !choosing.contains(token) else { return }
            let pending = BrowserPageDownload(
                id: String(token), url: URL(string: url), suggestedFilename: suggestedName,
                expectedBytes: totalBytes, state: .pending
            )
            choosing.insert(token)
            let delegate = page.uiDelegate
            Task { @MainActor [weak self, weak page] in
                let destination: URL?
                if let page, let delegate {
                    destination = await delegate.page(page, destinationForDownload: pending)
                } else {
                    destination = nil
                }
                guard let self, self.choosing.remove(token) != nil else { return }
                guard let destination else {
                    self.runtime.continueDownload(token: token, to: nil)
                    return
                }
                var download = pending
                download.destination = destination
                download.state = .inProgress
                self.downloads[token] = download
                self.runtime.continueDownload(token: token, to: destination.path)
                page?.emit(.downloadUpdated(download))
            }
        case let .progress(token, receivedBytes, totalBytes, _, _):
            guard var download = downloads[token] else { return }
            download.receivedBytes = receivedBytes
            download.expectedBytes = totalBytes ?? download.expectedBytes
            download.state = .inProgress
            downloads[token] = download
            page.emit(.downloadUpdated(download))
        case let .done(token, end, reason, _):
            // Chromium ended it while its file was being chosen.
            if choosing.remove(token) != nil { return }
            guard var download = downloads.removeValue(forKey: token) else { return }
            switch end {
            case .complete:
                download.state = .completed
                if let total = download.expectedBytes { download.receivedBytes = total }
            case .cancelled:
                download.state = .cancelled
            case .interrupted:
                download.state = .failed("interrupted (\(reason))")
            }
            page.emit(.downloadUpdated(download))
        }
    }

    /// Cancels (0), pauses (1) or resumes (2) one of the page's downloads.
    /// - Returns: Whether the download was running.
    @discardableResult
    func controlDownload(id: String, action: Int32) -> Bool {
        guard let token = Int32(id), downloads[token] != nil else { return false }
        return runtime.controlDownload(token: token, action: action)
    }
}

extension CEFBrowserPage {
    /// Cancels (0), pauses (1) or resumes (2) one of this page's downloads,
    /// by its ``BrowserPageDownload/id``.
    @discardableResult
    public func controlDownload(id: String, action: Int32) -> Bool {
        dataBridge.controlDownload(id: id, action: action)
    }
}
