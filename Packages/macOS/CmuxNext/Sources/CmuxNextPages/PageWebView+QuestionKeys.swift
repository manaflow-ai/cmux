import Foundation

extension PageWebView {
    /// Binds the agent pane's native pending question to Return in its Other field. Each key's
    /// proof is single-use; an incomplete answer leaves the next genuine key available. The page
    /// must label its fieldset with `data-cmux-question-session` and `data-cmux-question-id`.
    /// Those public labels never carry the isolated channel's nonce.
    ///
    /// `received` proves the focused DOM target and trusted key dispatch, not the person: the
    /// agent-pane owner must also consume its matching native person-key witness, and verify the
    /// question is still pending. Neither the generic user-input uptime nor page callbacks qualify.
    /// Returns false on any other page or engine, or before Chromium is attached.
    @discardableResult
    public func bindQuestionKeyTarget(_ target: PageQuestionKeyTarget?, received: @escaping (PageQuestionKeyTarget) -> Void) -> Bool {
        guard descriptor.id == PageDescriptor.agent.id, let chromiumSession, !isClosed else { return false }
        guard let target else {
            chromiumSession.questionKeys?.invalidate()
            return true
        }
        if chromiumSession.questionKeys == nil {
            let descriptor = descriptor
            chromiumSession.questionKeys = ChromiumQuestionKeyChannel(page: chromiumSession.page, owns: descriptor.owns)
        }
        chromiumSession.questionKeys?.bind(target, received: received)
        return true
    }
}
