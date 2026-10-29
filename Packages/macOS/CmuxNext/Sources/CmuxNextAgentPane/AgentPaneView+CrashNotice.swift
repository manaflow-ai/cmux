import AppKit
import CmuxNextDesign
import CmuxNextPages

/// A crashed page: the page host reloads it, unless it keeps crashing; then the pane says so and
/// waits for the user.
extension AgentPaneView {
    /// The page host's crash report; `reloading` is false once the page keeps crashing.
    func pageCrashed(reloading: Bool) {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        guard !reloading else { return } // the reloaded page reports its field ready again
        showCrashNotice()
        newTabPageFailed()
    }

    /// The New Tab page will not report its field ready (its load failed, or it crashed past its reload budget): the
    /// opening that holds keys for that field hears it now, so the keys drop instead of waiting for a field that
    /// never comes.
    func newTabPageFailed() {
        guard let token = model.newTab?.inputToken else { return }
        model.onNewTabInputFailed?(token)
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
