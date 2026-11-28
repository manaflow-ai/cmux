import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A crashed page: reload it, unless it keeps crashing; then the pane says so and waits for the
/// user (on the old host with its own count, on the page host with the page host's).
extension AgentPaneView {
    /// Reloads the page after its web content process crashed, unless it
    /// keeps crashing; then the pane says so and waits for the user.
    func webContentProcessDidTerminate() {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        if crashReloads.shouldReload(at: .now) {
            source.load(into: webView)
        } else {
            showCrashNotice()
        }
    }

    /// The page host's crash report: the same as ``webContentProcessDidTerminate()``, with the
    /// reload policy kept by the page host.
    func pageCrashed(reloading: Bool) {
        dictation.handle(.cancel)
        if !reloading { showCrashNotice() }
    }

    private func showCrashNotice() {
        guard crashNotice == nil else { return }
        let message = NSTextField(wrappingLabelWithString: Self.crashedMessage)
        message.alignment = .center
        let reload = NSButton(title: Self.reloadTitle, target: self, action: #selector(reloadAfterCrashes))
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
        for case let label as NSTextField in notice.subviews {
            label.textColor = tokens.textSecondary.nsColor
        }
    }

    @objc private func reloadAfterCrashes() {
        crashNotice?.removeFromSuperview()
        crashNotice = nil
        crashReloads = PageCrashReloads()
        if let page { page.reloadAfterCrashes() } else { source.load(into: webView) }
    }
}
