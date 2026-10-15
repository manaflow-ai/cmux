import CmuxBrowser
import CmuxCEF
import Foundation

/// A Chromium page's permission prompts and downloads, answered through the
/// page's UI delegate (the browser panel).
///
/// Permissions: Chromium's own bubble anchors to a toolbar cmux never shows,
/// so every request is answered here (the shim forwards every kind). A
/// grant accepts, a deny denies, and no answer leaves the request waiting
/// until Chromium ends it (never a dismissal, which Chromium counts toward
/// blocking the site for days). Chromium saves every answered prompt in its
/// content settings, so an answer cmux does not remember (one-time) is reset
/// to "ask" when the page next loads or closes, like Chrome's "Allow this
/// time", leaving the current page's grant working until then.
///
/// Downloads: the delegate chooses each download's file (nil cancels), and
/// the page reports progress and the end as ``BrowserPageEvent/downloadUpdated(_:)``.
/// Closing the page cancels its unfinished downloads in Chromium (they
/// belong to the profile and would otherwise keep running unseen).
@MainActor
final class CEFBrowserPageDataBridge {
    /// Permission prompts Chromium still waits on, by fork token.
    private var waitingPermissions: Set<Int32> = []
    /// One-time answers to reset when the page next loads or closes: (origin, content-setting type).
    private var oneTimeAnswers: [(origin: String, type: String)] = []
    /// Running downloads, by shim token.
    private var downloads: [Int32: BrowserPageDownload] = [:]
    /// Downloads waiting for their file, by shim token.
    private var choosing: Set<Int32> = []
    /// How downloads that ended were reported, by ``BrowserPageDownload/id``.
    private(set) var endedDownloads: [String: BrowserPageDownload.State] = [:]

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

    /// A main-frame load started: one-time answers have served their page.
    func pageWillLoad(_ page: CEFBrowserPage) {
        resetOneTimeAnswers(page: page)
    }

    /// The page is closing: reset one-time answers, cancel its downloads.
    func pageWillClose(_ page: CEFBrowserPage) {
        resetOneTimeAnswers(page: page)
        for token in downloads.keys {
            runtime.controlDownload(token: token, action: 0)
        }
        for token in choosing {
            runtime.continueDownload(token: token, to: nil)
        }
        downloads.removeAll()
        choosing.removeAll()
        waitingPermissions.removeAll()
    }

    // MARK: Permissions

    private func askPermission(token: Int32, bits: Int64, origin: String, page: CEFBrowserPage) {
        let request = BrowserChromiumPermissionRequest(cefPromptBits: UInt32(truncatingIfNeeded: bits))
        let pageRequest = request.pageRequest(origin: URL(string: origin))
        waitingPermissions.insert(token)
        let delegate = page.uiDelegate
        Task { @MainActor [weak self, weak page] in
            // Chromium may have ended the question before it got here.
            guard let page, self?.waitingPermissions.contains(token) == true else { return }
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
            self.answer(token: token, outcome: outcome, kinds: pageRequest.kinds, origin: origin)
        }
    }

    private func answer(
        token: Int32,
        outcome: BrowserPagePermissionCoordinator.Outcome,
        kinds: [BrowserPagePermissionRequest.Kind],
        origin: String
    ) {
        switch outcome.decision {
        case .grant:
            runtime.answerPermission(token: token, allow: true)
        case .deny:
            runtime.answerPermission(token: token, allow: false)
        case .prompt:
            return
        }
        guard outcome.isOneTime else { return }
        for kind in kinds {
            guard let type = BrowserChromiumPermissionRequest.contentSettingType(for: kind),
                  !oneTimeAnswers.contains(where: { $0.origin == origin && $0.type == type }) else { continue }
            oneTimeAnswers.append((origin, type))
        }
    }

    private func resetOneTimeAnswers(page: CEFBrowserPage) {
        guard !oneTimeAnswers.isEmpty else { return }
        let answers = oneTimeAnswers
        oneTimeAnswers.removeAll()
        guard let browserID = page.browser.browserID else { return }
        for answer in answers {
            runtime.setContentSetting(
                browser: browserID, origin: answer.origin, type: answer.type,
                value: BrowserChromiumPermissionRequest.contentSettingDefault
            )
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
        case let .done(token, end, reason, path):
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
            if end != .complete {
                removePartialFile(path, besides: download.destination)
            }
            endedDownloads[download.id] = download.state
            page.emit(.downloadUpdated(download))
        }
    }

    /// A partial file Chromium left (its `.crdownload` intermediate), only
    /// when it sits in the download's own temporary directory.
    private func removePartialFile(_ path: String, besides destination: URL?) {
        guard !path.isEmpty, let directory = destination?.deletingLastPathComponent().standardizedFileURL else { return }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent() == directory, file != destination?.standardizedFileURL else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: file)
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

    /// How a download of this page ended, if it did (a report still queued
    /// when the panel closes the page is not lost: the panel saves a
    /// completed download instead of cancelling it).
    public func endedDownloadState(id: String) -> BrowserPageDownload.State? {
        dataBridge.endedDownloads[id]
    }
}
