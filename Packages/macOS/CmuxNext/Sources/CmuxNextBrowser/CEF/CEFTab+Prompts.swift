import Foundation

/// Prompts of a Chromium tab that cmux asks itself (Chromium shows its own
/// JavaScript dialogs and permission bubbles): the automatic-downloads
/// question. The chrome's prompt bar shows the first pending one, over the
/// page (an occlusion of the page window).
extension CEFTab {
    func enqueuePrompt(_ kind: BrowserPromptKind, origin: String, completion: @escaping (BrowserPromptResponse) -> Void) {
        guard !isClosed else {
            completion(BrowserPrompt(kind: kind, origin: origin, completion: { _ in }).dismissalResponse)
            return
        }
        var prompt: BrowserPrompt?
        prompt = BrowserPrompt(kind: kind, origin: origin) { [weak self] response in
            self?.pendingPrompts.removeAll { $0 === prompt }
            completion(response)
        }
        if let prompt { pendingPrompts.append(prompt) }
    }

    /// The tab closed: every open question gets its dismissal answer.
    func dismissPrompts() {
        let prompts = pendingPrompts
        pendingPrompts.removeAll()
        for prompt in prompts { prompt.respond(prompt.dismissalResponse) }
    }

    func makeAutomaticDownloadGate() -> AutomaticDownloadGate {
        let profile = profileID
        return AutomaticDownloadGate(
            permissions: { [weak self] in (self?.pageInfoSettings ?? .shared).permissions(for: profile) },
            ask: { [weak self] site, answer in
                guard let self else { return answer(.cancel) }
                enqueuePrompt(.permission(.automaticDownloads), origin: site, completion: answer)
            }
        )
    }

    /// cmux's gate is the one automatic-downloads rule: Chromium's own
    /// limiter (`DownloadRequestLimiter`, which would ask with its own
    /// bubble before cmux sees the download) gets the profile default
    /// "allow". CEF does not set defaults of an incognito context; there
    /// Chromium's limiter stays as it is.
    func leaveAutomaticDownloadsToCmux(_ browser: Int32) {
        guard runtime.contentSetting(browser, url: nil, kind: .automaticDownloads) != .allow else { return }
        runtime.setContentSetting(browser, url: "", kind: .automaticDownloads, value: .allow)
    }
}
