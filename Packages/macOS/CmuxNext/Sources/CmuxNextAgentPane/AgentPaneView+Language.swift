import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages

extension AgentPaneView {
    /// Hands the page `app.language` (nil: System): the page host's ``PageWebView`` takes it
    /// itself; the old host's document gets the same call (``PageWebView/languageScript(_:)``) on
    /// load, on the handshake and on every change, so the chat switches language live.
    func applyLanguage() {
        if let page {
            page.applyLanguage()
            return
        }
        evaluateScript(PageWebView.languageScript(DesignSettings.shared.appLanguage))
    }

    /// The old host only: `AppLanguageApplier` pushes every change to the registered pages, which
    /// the page host's ``PageWebView`` is and the old host's web view is not.
    func observeLanguage() {
        guard page == nil else { return }
        // task-owner: this pane (cancelled in close() and deinit); event-driven (Observation).
        languageObservation = Task { [weak self] in
            for await _ in ObservationStream({ DesignSettings.shared.appLanguage }) {
                guard let self else { return }
                self.applyLanguage()
            }
        }
    }

    /// A pane whose handshake loop stopped past its bound (hostRetry.ts `hostRetryStep`) asks again
    /// when this app's acpmux is back: each lookup that answers (``AcpmuxHost``, any pane's, Settings'
    /// or a restart's) tells every page `acpmux-daemon-answered`. A page still connected or still
    /// asking ignores it (hostRetry.ts `hostWakeAsks`); there is no tick.
    func observeAcpmuxAnswers() {
        // task-owner: this pane (cancelled in close() and deinit); event-driven (NotificationCenter).
        acpmuxAnswerObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cmuxNextAcpmuxAnswered).map({ _ in () }) {
                guard let self else { return }
                self.evaluateScript("window.dispatchEvent(new Event('acpmux-daemon-answered'))")
            }
        }
    }
}

public extension Notification.Name {
    /// This app's acpmux answered a lookup (``AcpmuxHost``): a stopped pane asks again.
    static let cmuxNextAcpmuxAnswered = Notification.Name("cmux.next.acpmux-answered")
}
