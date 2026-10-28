import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A crashed page shows the crash notice and waits for the person's Reload when its page host
/// keeps no automatic reload for it (the agent chat: a reload by itself would build the chat again
/// without what its page held, an open menu or popover, the caret, an IME composition, chips not
/// yet sent; Leo, 2026-10-26: "why does cmux-next's browser keep refreshing and reloading?").
/// The page host owns that policy (`PageWebView.reloadsAfterCrash`).
extension AgentPaneView {
    /// The page host's crash report; `reloading` is false when the page host does not reload it.
    func pageCrashed(reloading: Bool) {
        // The composer that held the session's words is gone.
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
        page.reloadAfterCrashes()
    }
}
