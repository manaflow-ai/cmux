import Foundation
import os

extension CEFTab {
    /// An agent-driven tab never completes a passkey ceremony (plans/cmux-next/passkeys.md 3.5): the fork
    /// refuses each WebAuthn create and get of the tab with NotAllowedError before an authenticator is
    /// asked (`cmux_tab_set_webauthn_mode`, API 23), so an agent's click shows no Touch ID sheet, account
    /// chooser or phone QR code over the person's work. Called when a live tab becomes agent-driven and
    /// when its browser attaches (a tab marked before its browser exists), before the page loads. Popups
    /// the tab opens start refused (the fork copies the mode). A tab stays refused: `markAgentDriven` is
    /// one-way.
    func applyWebAuthnRefusal() {
        guard isAgentDriven, let browserID, runtime.state == .ready, let shim = runtime.shim else { return }
        if shim.setWebAuthnMode(browserID, 1) != 1 {
            // Fails open only on a fork without the call; say so (no URL in the line).
            runtime.logger.error("passkeys stay allowed in agent-driven browser \(browserID, privacy: .public): fork has no WebAuthn refusal")
        }
    }
}
