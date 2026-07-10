public import CMUXMobileCore

/// The trust decision for a dialed iroh EndpointId against the one pinned for a
/// device (plans/feat-ios-iroh/DESIGN.md, "Security and E2E story").
///
/// The threat is credential exfiltration: the phone sends its Stack access token
/// inside the protocol on every RPC, so a substituted route (compromised
/// registry, authz bug, malicious route write) must never receive a live token.
/// The iroh channel is cryptographically bound to the dialed EndpointId, so
/// pinning that id and refusing token-bearing traffic to a changed id closes the
/// hole the host:port baseline cannot.
public enum CmxEndpointPinDecision: Sendable, Equatable {
    /// The dialed id matches the pinned id: a fully trusted connection.
    case trusted
    /// No id is pinned yet. Trust on first use (TOFU): the caller pins this id,
    /// no weaker than today's registry-trusted baseline and strictly stronger
    /// afterward. The associated value is the id to pin.
    case firstTrust(String)
    /// The dialed id differs from the pinned id. This is surfaced to the user
    /// for explicit re-trust and never silently accepted; no token-bearing
    /// traffic may flow until the user re-trusts.
    case mismatch(pinned: String, dialed: String)
}

/// Evaluates whether a dialed iroh peer may carry Stack tokens, given the id
/// pinned for its device. Pure and side-effect-free: persistence of the pin
/// (Keychain / `MobilePairedMacStore`) and the re-trust UI live in the caller.
public struct CmxEndpointPinGate: Sendable {
    public init() {}

    /// Classifies `dialedEndpointID` against the `pinnedEndpointID` recorded for
    /// the device (nil or empty when nothing is pinned yet).
    public func evaluate(
        dialedEndpointID: String,
        pinnedEndpointID: String?
    ) -> CmxEndpointPinDecision {
        guard let pinnedEndpointID, !pinnedEndpointID.isEmpty else {
            return .firstTrust(dialedEndpointID)
        }
        if pinnedEndpointID == dialedEndpointID {
            return .trusted
        }
        return .mismatch(pinned: pinnedEndpointID, dialed: dialedEndpointID)
    }

    /// Whether Stack access tokens may be sent for a decision. A first-trust
    /// connection may carry tokens (it pins on the same attach, TOFU); a
    /// mismatch may not until the user re-trusts.
    public func allowsStackTokens(for decision: CmxEndpointPinDecision) -> Bool {
        switch decision {
        case .trusted, .firstTrust:
            return true
        case .mismatch:
            return false
        }
    }

    /// The id that should be persisted as the new pin for a decision, if any.
    /// First trust pins the dialed id; a steady-state trusted connection needs
    /// no write; a mismatch must not auto-pin (it awaits explicit re-trust).
    public func endpointIDToPin(for decision: CmxEndpointPinDecision) -> String? {
        switch decision {
        case let .firstTrust(id):
            return id
        case .trusted, .mismatch:
            return nil
        }
    }
}
