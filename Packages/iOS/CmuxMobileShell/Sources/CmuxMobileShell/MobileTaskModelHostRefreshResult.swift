internal import CmuxMobileRPC
import CmuxMobileShellModel

/// The host result and retry classification from one model discovery attempt.
struct MobileTaskModelHostRefreshResult: Sendable {
    let result: MobileTaskModelListResult?
    let outcome: MobileTaskModelRefreshOutcome
}
