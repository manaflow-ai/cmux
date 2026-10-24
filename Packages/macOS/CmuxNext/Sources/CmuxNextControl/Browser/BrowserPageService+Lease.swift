public import CmuxNextSettings
import Foundation

/// The per-tab agent lease on every `browser.page.*` write verb (#24413).
///
/// Any agent may drive any app browser tab, in any profile, extensions or
/// not: safety is coordination, not exclusion. A write verb whose request
/// names an `agent` claims the tab for that agent; while the claim lasts,
/// another agent's write answers `lease_held` with the holder's name, so two
/// agents never race on one page. Reads (``rightReadVerbs`` and the cookie
/// and storage getters) never claim or wait. `browser.page.state` names the
/// current `driver`; `browser.page.right` `release` hands the tab on. A
/// request without an agent name (the person's script, an older CLI) is not
/// leased.
extension BrowserPageService {
    /// How long a direct verb's claim outlives the agent's last write: long
    /// enough to cover the pauses between one agent's steps, short enough
    /// that a finished agent frees the tab soon after.
    static let verbLeaseTTL: Duration = .seconds(90)

    /// Methods that never claim a tab: the reads, `browser.page.right` (which
    /// leases on its own), and the cookie and storage getters.
    static let leaseFreeMethods: Set<String> = rightReadVerbs.union([
        "browser.page.right", "browser.page.cookies.get", "browser.page.storage.get",
    ])

    /// `method`, claiming its tab for the request's agent first when it writes.
    func leasing(_ method: ControlMethod) -> ControlMethod {
        guard method.name.hasPrefix("browser.page."), !Self.leaseFreeMethods.contains(method.name) else { return method }
        let leases = leases
        return method.wrappingAsync { call, body in
            // An unknown tab is the body's error to report, as before.
            if let agent = Self.optionalString(call, "agent"), let tab = try? Self.tab(call),
               let holder = await leases.acquire(tab.id, for: agent, lasting: Self.verbLeaseTTL) {
                throw Self.leaseHeld(holder: holder, tab: tab.id)
            }
            return try await body(call)
        }
    }

    /// The answer to a write on a tab another agent drives.
    static func leaseHeld(holder: String, tab: String) -> ControlError {
        ControlError(code: "lease_held",
                     message: ControlStrings.format("control.error.rightLeaseHeld",
                                                    "%@ is driving this tab; wait, or open your own tab with a URL", holder),
                     data: ["holder": .string(holder), "tab": .string(tab)])
    }
}
