import Foundation

extension CEFTab {
    public func markAgentDriven() {
        guard !isAgentDriven else { return }
        isAgentDriven = true
        applyPasswordFill()
    }

    /// Chromium fills passwords by default; only an agent-driven tab turns it
    /// off (again on attach, for a page that was still being created).
    func applyPasswordFill() {
        // Turned off through the fork's cmux_tab_set_password_fill (API 15); an older fork has no autofill switch to turn.
        guard isAgentDriven, let browserID, runtime.state == .ready else { return }
        _ = runtime.shim?.setPasswordFill(browserID, 0)
    }
}
