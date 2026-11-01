import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A crashed page shows the crash notice and waits for the person's Reload, on either host: a
/// reload by itself would build the chat again without what its page held (an open menu or
/// popover, the caret, an IME composition, chips not yet sent), and a page never reloads unless
/// the person asks (Leo, 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?").
extension AgentPaneView {
    /// The old host's web content process ended (`termination`: WebKit's reason and pid, or an
    /// injected end in tests): logged with its siblings (``AgentPageTerminations``), the notice, no
    /// automatic reload.
    func webContentProcessDidTerminate(_ termination: PageTermination = .unknown) {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        terminations.ended(self, termination: termination.withPid(fallback: knownWebContentPid))
        showCrashNotice()
    }

    /// The page host's crash report: the same as ``webContentProcessDidTerminate(_:)``, with the
    /// reload policy kept by the page host.
    func pageCrashed(reloading: Bool) {
        dictation.handle(.cancel)
        guard !reloading else { return }
        terminations.ended(self, termination: page?.lastTermination ?? .unknown)
        showCrashNotice()
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
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }
}
