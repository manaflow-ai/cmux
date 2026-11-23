import Foundation
import os

extension CEFTab {
    /// An agent-driven tab never completes a passkey ceremony the agent starts (plans/cmux-next/passkeys.md 3.5): the
    /// fork refuses each WebAuthn create and get of the tab with NotAllowedError before an authenticator is asked
    /// (`cmux_tab_set_webauthn_mode`, API 23), so an agent's click shows no Touch ID sheet, account chooser or phone QR
    /// code over the person's work. Called when a live tab becomes agent-driven, at each agent action after that
    /// (``markAgentDriven()``; an agent's reads, ``markAgentReading()``, refuse nothing, as in Chrome, which refuses only
    /// while its agent is in control: the Chief's 5 s watch of Google's passkey page refused the request the page made
    /// after the person's click, 2026-11-20), and when its browser attaches (a tab marked before its browser exists), before the page
    /// loads. Popups the tab opens start refused (the fork copies the mode). The person takes the page back with their
    /// own input in it (``allowWebAuthnForPerson()``), as in Chrome, where the person's click runs their security key.
    func applyWebAuthnRefusal() {
        guard isAgentDriven, webAuthnAgentActs, !webAuthnRefused, webAuthnHandOvers == 0 else { return }
        webAuthnRefused = setWebAuthnMode(1)
    }

    /// The person took the page over: their own mouse down, mouse up or key in it (``CEFLinkClickTracker``'s input
    /// hook, an `NSEvent` local monitor; an agent's input goes through DevTools and never reaches it), or their click
    /// on an agent's passkey request (``handOverWebAuthn(during:)``). Chromium's WebAuthn runs (CMUX_WEBAUTHN_MODE_ALLOW)
    /// until the next agent action. Cloudflare's "Verify with a security key" (2026-11-20): an agent drove the tab to
    /// the 2FA step, and every try of the person's got NotAllowedError in 6 ms, before any key was asked.
    /// Chromium checks the mode only when a request starts, so an agent's later read does not end the person's ceremony.
    public func allowWebAuthnForPerson() {
        // The page is the person's until the agent acts again; the agent's reads keep it so (``markAgentReading()``).
        webAuthnAgentActs = false
        guard webAuthnRefused else { return }
        webAuthnRefused = !setWebAuthnMode(0)
    }

    /// An agent acts in the page again: a person's hand-over ends and WebAuthn is refused. The same as
    /// ``markAgentDriven()`` on a marked tab.
    public func refuseWebAuthnForAgent() {
        guard isAgentDriven else { return }
        webAuthnAgentActs = true
        applyWebAuthnRefusal()
    }

    /// Runs a passkey hand-off's `trigger` (the click on the page's passkey button, after the person clicked the
    /// request) with the page handed to the person: the agent action that carries the trigger does not refuse again.
    public func handOverWebAuthn(during trigger: @Sendable () async throws -> Void) async throws {
        allowWebAuthnForPerson()
        webAuthnHandOvers += 1
        defer {
            webAuthnHandOvers -= 1
            // The trigger's own click is an agent call; the page stays the person's after it.
            if webAuthnHandOvers == 0 { webAuthnAgentActs = false }
        }
        try await trigger()
    }

    /// Sets the fork's WebAuthn mode of this tab's browser; true when the fork took it.
    private func setWebAuthnMode(_ mode: Int32) -> Bool {
        guard let browserID, runtime.state == .ready, let shim = runtime.shim else { return false }
        guard shim.setWebAuthnMode(browserID, mode) == 1 else {
            // Fails open only on a fork without the call; say so (no URL in the line).
            runtime.logger.error("passkeys: fork took no WebAuthn mode \(mode, privacy: .public) for browser \(browserID, privacy: .public)")
            return false
        }
        return true
    }
}
