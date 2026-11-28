internal import CmuxMobileRPC
import CmuxMobileShellModel

/// The host result and retry classification from one model discovery attempt.
struct MobileTaskModelHostRefreshResult: Sendable {
    let result: MobileTaskModelListResult?
    let outcome: MobileTaskModelRefreshOutcome
    /// The exact client identity that produced a validated host response.
    /// Keeping it with the result prevents a connection replacement between
    /// response validation and cache publication from rebinding stale data.
    let connectionIdentity: String?

    init(
        result: MobileTaskModelListResult?,
        outcome: MobileTaskModelRefreshOutcome,
        connectionIdentity: String? = nil
    ) {
        self.result = result
        self.outcome = outcome
        self.connectionIdentity = connectionIdentity
    }
}
