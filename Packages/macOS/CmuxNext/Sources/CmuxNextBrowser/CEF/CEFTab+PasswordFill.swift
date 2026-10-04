import Foundation
import os

extension CEFTab {
    public func markAgentDriven() {
        guard !isAgentDriven else { return }
        isAgentDriven = true
        applyPasswordFill()
        CEFAgentURLGuard.leave(self, committedURL ?? state.url)
    }

    /// Chromium fills passwords by default; only an agent-driven tab turns it
    /// off (again on attach, for a page that was still being created).
    func applyPasswordFill() {
        // Turned off through the fork's cmux_tab_set_password_fill (API 15); an older fork has no autofill switch to turn.
        guard isAgentDriven, let browserID, runtime.state == .ready else { return }
        if runtime.shim?.setPasswordFill(browserID, 0) != 1 {
            // Fails open on a fork without the switch; say so (no URL or value in the line).
            runtime.logger.notice("password fill stays on for agent-driven browser \(browserID, privacy: .public): fork has no switch")
        }
    }
}
