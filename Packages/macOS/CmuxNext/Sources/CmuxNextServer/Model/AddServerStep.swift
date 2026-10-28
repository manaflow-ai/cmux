import Foundation

/// Where the Add Server sheet is, derived from ``ServerModel`` (the draft code, the candidate the
/// cloud found, the intents in flight and the last answer). The sheet draws one layout per step,
/// and the buttons and keys follow from it (``AddServerButton``), so nothing in the view decides
/// state on its own.
public nonisolated enum AddServerStep: Equatable, Sendable {
    /// The code is empty or incomplete.
    case enterCode
    /// A complete code went to the cloud; no answer yet.
    case lookingUp
    /// The cloud refused the code (no server waits with it, it expired, signed out, offline).
    case codeRefused(String)
    /// The server was found: check its facts and four words, then Approve.
    case review(PairingCandidate)
    /// Approve went to the cloud; no answer yet.
    case approving(PairingCandidate)
    /// Approve was refused; Return tries again.
    case approveFailed(PairingCandidate, String)
    /// The server was added under this display name.
    case added(String)
}
