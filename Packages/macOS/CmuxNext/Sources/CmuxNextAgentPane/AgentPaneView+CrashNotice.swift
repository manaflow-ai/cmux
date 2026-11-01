import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A page whose web content process ended loads again by itself in a new process
/// (``AgentPageCrashRetry``): at once when the pane is on screen, else when it is next shown, with
/// no notice meanwhile (Leo, 2026-11-01: "how come it says this??? why doens't it just retry on its
/// own"). Only a page that keeps ending (3 retries in 60 s) shows the crash notice and waits for
/// the person's Reload. The process already took what the page held (an open menu, the caret,
/// unsent chips), so a retry loses nothing a Reload would keep.
extension AgentPaneView {
    /// The old host's web content process ended (`termination`: WebKit's reason and pid, or an
    /// injected end in tests): logged with its siblings (``AgentPageTerminations``), then a retry
    /// or the notice.
    func webContentProcessDidTerminate(_ termination: PageTermination = .unknown) {
        contentEnded(termination.withPid(fallback: knownWebContentPid))
    }

    /// The page host's crash report: the same as ``webContentProcessDidTerminate(_:)``, with the
    /// reload policy kept by the page host.
    func pageCrashed(reloading: Bool) {
        guard !reloading else {
            dictation.handle(.cancel)
            return
        }
        contentEnded(page?.lastTermination ?? .unknown)
    }

    private func contentEnded(_ termination: PageTermination) {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        let retries = crashRetry.ended(self)
        terminations.ended(self, termination: termination, retries: retries)
        if !retries { showCrashNotice() }
    }

    /// Loads the page again in a new process (an automatic retry): WebKit starts a new web
    /// content process for the load, Chromium a new renderer.
    func retryAfterCrash() {
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }

    private func showCrashNotice() {
        guard crashNotice == nil else { return }
        let message = ChromeLabel(wrappingLabelWithString: Self.crashedMessage)
        message.alignment = .center
        let reload = ThemedBezelButton(title: Self.reloadTitle, target: self, action: #selector(reloadAfterCrashes))
        let notice = NSStackView(views: [message, reload])
        notice.orientation = .vertical
        notice.spacing = 12
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        let inset = notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        // A pane narrower than the inset clips the notice instead of
        // breaking the layout.
        inset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: centerYAnchor),
            inset,
        ])
        crashNotice = notice
        themeCrashNotice(themeTokens)
    }

    /// The notice sits on the pane's background, so it takes the pane's
    /// theme rather than the system appearance.
    func themeCrashNotice(_ tokens: ThemeTokens) {
        guard let notice = crashNotice else { return }
        notice.appearance = NSAppearance(named: tokens.isDark ? .darkAqua : .aqua)
        for case let label as ChromeLabel in notice.subviews {
            label.textColor = tokens.textSecondary.nsColor
        }
    }

    /// The page finished loading a document after its end: it lives, so the notice goes and the
    /// chat leaves its crash group (a sibling's Reload must not reload it). The notice showed over a
    /// working chat before this (user report 2026-10-30): a host route, a retarget or a WebKit
    /// fallback had loaded the page again, and only Reload took the notice away.
    func pageLoadedAgain() {
        // A page that came back before its owed retry ran needs none.
        crashRetry.cancel()
        guard let notice = crashNotice else { return }
        notice.removeFromSuperview()
        crashNotice = nil
        terminations.loadedAgain(self, session: model.sessionId)
    }

    /// The notice's Reload: the person's request for every chat that ended with this one.
    @objc private func reloadAfterCrashes() {
        terminations.reload(from: self)
    }

    /// Takes the notice away and reloads this pane's page (a Reload the person pressed here or in
    /// a chat that ended with this one).
    func reloadAfterCrash() {
        crashNotice?.removeFromSuperview()
        crashNotice = nil
        crashReloadCount += 1
        // The person's Reload: the next end retries again.
        crashRetry.cancel()
        crashRetry.budget.reset()
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }
}
