public import CmuxBrowser
import CmuxCEF
import Foundation
import os

/// Chromium's password manager in a page: whether it fills saved passwords,
/// and its offers to save a submitted sign-in (cmux Next `CEFTab+PasswordFill`
/// and `CEFPasswordPrompts`).
///
/// Filling: a page an agent drives never gets a saved password filled, so an
/// automated click cannot hand one to page script (``PasswordFillPolicy``).
/// The switch (`cmux_shim_set_password_fill`, fork API 15) is sent when the
/// browser exists, before its first document, and again for a browser the
/// page recreates. A fork without the switch fails open, and says so.
///
/// Offers: asked through the UI delegate's
/// ``BrowserPagePasswordPromptDelegate`` (the panel's prompt strip) and
/// answered through `cmux_shim_password_prompt_answer` (fork API 20). Never
/// asked in an agent-driven page: Chromium does not offer there, and this
/// holds even on a fork that does.
extension CEFBrowserPage {
    private static let passwordLogger = Logger(subsystem: "com.cmuxterm.app", category: "browser.chromium.passwords")

    /// Marks the page agent-driven for the rest of its life: password filling
    /// goes off and waiting save offers are dismissed. A live page that may
    /// hold a password Chromium filled before is reopened from its history
    /// (a password field's value is never part of it).
    /// - Returns: `true` when the page was reopened.
    @discardableResult
    public func markAgentDriven() -> Bool {
        guard !isAgentDriven else { return false }
        isAgentDriven = true
        let mayHoldFilledPassword = browser.browserID != nil && passwords.fill.sentFillOn
            && Self.holdsDocument(browser.state.url)
        applyPasswordFill()
        endPasswordOffers(answer: true)
        guard mayHoldFilledPassword else { return false }
        Self.passwordLogger.notice("reopening an agent-driven page that could hold a filled password")
        if browser.releaseContent() {
            browser.restoreContent()
        } else {
            // Not releasable now (a popup still moving to its window): a
            // reload drops a filled password too; fill is off for the new document.
            browser.reload()
        }
        return true
    }

    /// Whether `url` is a document Chromium could have filled a password in.
    nonisolated static func holdsDocument(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "about"
    }

    /// Sends the page's fill switch when Chromium needs a change; again for
    /// a browser the page recreated (Memory Saver, a reopen).
    func applyPasswordFill() {
        guard let id = browser.browserID, let shim = CEFRuntime.shared.shim else { return }
        if passwords.browserID != id {
            passwords.browserID = id
            passwords.fill.browserRecreated()
        }
        guard let value = passwords.fill.nextSwitchValue(agentDriven: isAgentDriven) else { return }
        let applied = shim.setPasswordFill(id, value) == 1
        // No URL or password in these lines.
        Self.passwordLogger.info("password fill \(value == 1 ? "on" : "off", privacy: .public) for browser \(id, privacy: .public) applied=\(applied, privacy: .public)")
        if !applied, value == 0 {
            Self.passwordLogger.notice("password fill stays on for browser \(id, privacy: .public): fork has no switch")
        }
    }

    /// A save offer from Chromium, or the end of one.
    func handlePasswordPrompt(promptID: Int32, json: String) {
        guard let message = CEFPasswordPromptMessage(json: json) else { return }
        // Neither the site nor the user name in the line.
        Self.passwordLogger.info("password prompt \(promptID, privacy: .public) \(message == .gone ? "gone" : "offer", privacy: .public) agentDriven=\(self.isAgentDriven, privacy: .public)")
        let delegate = uiDelegate as? any BrowserPagePasswordPromptDelegate
        switch message {
        case .gone:
            guard passwords.offers.removeValue(forKey: promptID) != nil else { return }
            delegate?.page(self, didEndPasswordSaveOffer: Int(promptID))
        case let .offer(origin, username, isUpdate):
            guard !isAgentDriven, let delegate, let url = URL(string: origin), url.host != nil else {
                Self.answerPasswordPrompt(promptID, .dismiss)
                return
            }
            let offer = BrowserPagePasswordSaveOffer(id: Int(promptID), origin: url, username: username, isUpdate: isUpdate)
            passwords.offers[promptID]?.cancel()
            passwords.offers[promptID] = Task { @MainActor [weak self, weak delegate] in
                guard let self, let delegate else { return }
                let answer = await delegate.page(self, offerToSavePassword: offer)
                // Chromium dropped it meanwhile, or it was dismissed already.
                guard self.passwords.offers.removeValue(forKey: promptID) != nil else { return }
                Self.answerPasswordPrompt(promptID, Self.action(for: answer, isUpdate: isUpdate))
            }
        }
    }

    /// Ends every waiting offer: dismissed in Chromium when `answer` (the
    /// page stays; on close Chromium drops them itself), and gone from the strip.
    func endPasswordOffers(answer: Bool) {
        let ids = Array(passwords.offers.keys)
        guard !ids.isEmpty else { return }
        let delegate = uiDelegate as? any BrowserPagePasswordPromptDelegate
        for id in ids {
            passwords.offers.removeValue(forKey: id)?.cancel()
            if answer { Self.answerPasswordPrompt(id, .dismiss) }
            delegate?.page(self, didEndPasswordSaveOffer: Int(id))
        }
    }

    /// The fork's action for the person's answer: Save becomes Update for a
    /// saved sign-in, which has no Never; no answer dismisses.
    nonisolated static func action(for answer: BrowserPagePasswordSaveAnswer?, isUpdate: Bool) -> CEFPasswordPromptAction {
        switch answer {
        case .save?: isUpdate ? .update : .save
        case .never?: isUpdate ? .dismiss : .never
        case .notNow?, nil: .dismiss
        }
    }

    private static func answerPasswordPrompt(_ promptID: Int32, _ action: CEFPasswordPromptAction) {
        let accepted = CEFRuntime.shared.shim?.passwordPromptAnswer(promptID, action.rawValue, nil) == 1
        passwordLogger.info("password prompt \(promptID, privacy: .public) answered \(action.rawValue, privacy: .public) accepted=\(accepted, privacy: .public)")
    }
}
