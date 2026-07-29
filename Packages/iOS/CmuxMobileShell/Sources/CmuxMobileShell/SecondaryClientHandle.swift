import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// The live client to a secondary Mac plus the route/ticket it was dialed on.
struct SecondaryClientHandle {
    let client: MobileCoreRPCClient
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Authority expected by the paired row when this client was established.
    let storedInstanceTag: String?
    /// Instance identity proven by this client's authenticated host status.
    let authenticatedInstanceTag: String?
    let supportedHostCapabilities: Set<String>
    let actionCapabilities: MobileWorkspaceActionCapabilities
}

/// Whether a background control connection can be retried without a new
/// authority or route edge.
enum SecondaryClientAttempt {
    case connected(SecondaryClientHandle)
    /// The route was authorized and compatible, but the network exchange failed.
    case transientFailure
    /// The saved route, authenticated identity, or host response is incompatible.
    case permanentFailure
}

enum SecondaryHostStatusAttempt {
    case received(MobileHostStatusResponse)
    case transientFailure
    case permanentFailure
}

enum SecondaryWorkspaceFetchAttempt {
    case received([MobileWorkspacePreview])
    case transientFailure
    case permanentFailure
}

enum SecondaryMacEstablishmentOutcome {
    case connected
    case transientFailure
    case permanentFailure
    /// Scope or ownership changed while the attempt was in flight.
    case superseded
}

enum SecondaryEventSubscriptionActivation {
    case failed
    /// `requiresCatchUp` is true when the host installed a missing
    /// registration and events emitted before the acknowledgement were lost.
    case active(requiresCatchUp: Bool)
}
