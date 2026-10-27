import Foundation
import os

extension CEFTab {

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
    /// The fork API that added cmux_tab_set_password_fill.
    static let switchForkAPI: Int32 = 15

    static func apply(_ tab: CEFTab) {
        guard let browserID = tab.browserID, tab.runtime.state == .ready, let shim = tab.runtime.shim,
              let value = tab.passwordFill.nextSwitchValue(agentDriven: tab.isAgentDriven) else { return }
        // Whether the fork has the switch is the mirrored fork API version, not the call's answer:
        // the call is one-way, ordered before any later op of the tab.
        guard tab.runtime.forkAPIVersion >= switchForkAPI else {
            // Fails open on a fork without the switch; say so (no URL or value in the line).
            if value == 0 { tab.runtime.logger.notice("password fill stays on for browser \(browserID, privacy: .public): fork has no switch") }
            return
        }
        _ = shim.setPasswordFill(browserID, value)
    }
}
