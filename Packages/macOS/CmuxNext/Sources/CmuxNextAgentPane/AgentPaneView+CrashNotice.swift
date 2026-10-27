import AppKit
import CmuxNextDesign
import CmuxNextPages
import os

private let crashLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")

/// A crashed page shows the crash notice and waits for the person's Reload, on either host: a
/// reload by itself would build the chat again without what its page held (an open menu or
/// popover, the caret, an IME composition, chips not yet sent), and a page never reloads unless
/// the person asks (Leo, 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?").
extension AgentPaneView {
    /// The old host's web content process crashed: the notice, no automatic reload.
    func webContentProcessDidTerminate() {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        crashLogger.error("agent pane web content ended; no automatic reload (the crash notice offers Reload)")
        showCrashNotice()
    }

    /// The page host's crash report: the same as ``webContentProcessDidTerminate()``, with the
    /// reload policy kept by the page host.
    func pageCrashed(reloading: Bool) {
        dictation.handle(.cancel)
        if !reloading { showCrashNotice() }
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

    @objc private func reloadAfterCrashes() {
        crashNotice?.removeFromSuperview()
        crashNotice = nil
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }
}
