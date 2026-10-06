import Foundation
import os

extension CEFTab {
    var passwordFills: Bool { passwordFill.fills(agentDriven: isAgentDriven) }

    public func setPasswordFillAllowedByProfile(_ allowed: Bool) {
        if passwordFill.setAllowedByProfile(allowed) { applyPasswordFill() }
    }

    public func markAgentDriven() {
        guard !isAgentDriven else { return }
        isAgentDriven = true
        applyPasswordFill()
        CEFAgentURLGuard.applyShimGuard(self)
        CEFAgentURLGuard.leave(self, committedURL ?? state.url)
    }

    func applyPasswordFill() { CEFPasswordFill.apply(self) }
}

/// Sends a tab's `PasswordFillState` decision through the fork's
/// cmux_tab_set_password_fill (API 15), again on attach for a page that was
/// still being created; an older fork has no switch to turn.
enum CEFPasswordFill {
    static func apply(_ tab: CEFTab) {
        guard let browserID = tab.browserID, tab.runtime.state == .ready,
              let value = tab.passwordFill.nextSwitchValue(agentDriven: tab.isAgentDriven) else { return }
        if tab.runtime.shim?.setPasswordFill(browserID, value) != 1, value == 0 {
            // Fails open on a fork without the switch; say so (no URL or value in the line).
            tab.runtime.logger.notice("password fill stays on for browser \(browserID, privacy: .public): fork has no switch")
        }
    }
}
