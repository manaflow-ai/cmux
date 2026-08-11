#if os(iOS)
import CmuxMobileShellModel

/// Identity that restarts model resolution when the provider, selected Mac, or
/// live foreground connection changes.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
    let connectedMacPairingID: String?

    /// Equality identifies the owner of a refresh, not the mutable connection
    /// it may promote. A selected-Mac probe must survive its own foreground
    /// switch instead of being cancelled by SwiftUI's identity observer.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider
            && lhs.macPairingID == rhs.macPairingID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(macPairingID)
    }

    /// A connection transition that prevented authoritative discovery gets
    /// one follow-up refresh from the settled connection. Successful host
    /// discovery already observed that transition and must not be repeated.
    func shouldRefreshAgain(
        connectedMacPairingID currentConnectionID: String?,
        source: MobileTaskModelListSource?
    ) -> Bool {
        connectedMacPairingID != currentConnectionID
            && source != .discovered
    }
}
#endif
