/// Every reason a dial can start, classified once so the supervisor can apply
/// one uniform policy: automatic triggers JOIN or COALESCE into an in-flight
/// attempt, explicit intent REPLACES it. The August 2026 field logs recorded
/// 35 of 57 reconnect failures as "superseded by a newer attempt" because
/// automatic triggers raced each other; classification at the entry funnel is
/// the structural fix.
public enum PeerDialTrigger: Sendable, Hashable, CustomStringConvertible {
    /// App launch / stored-Mac restore.
    case launch
    /// The user tapped retry / reconnect.
    case manualRetry
    /// The user changed the connection method (for example Tailscale Only),
    /// which must re-dial even while connected.
    case connectionMethodChanged
    /// NWPathMonitor reported a network path change.
    case networkPathChanged
    /// The scene became active.
    case foreground
    /// A presence push reported the peer's routes changed.
    case presencePush
    /// A scheduled retry ladder fired.
    case backoffExpired

    /// Explicit user intent replaces an in-flight attempt; automatic triggers
    /// join it instead.
    public var isExplicit: Bool {
        switch self {
        case .manualRetry, .connectionMethodChanged:
            return true
        case .launch, .networkPathChanged, .foreground, .presencePush, .backoffExpired:
            return false
        }
    }

    /// Automatic triggers that arrive while connected are satisfied by the
    /// live session. Explicit triggers re-dial even when connected.
    public var redialsWhileReady: Bool {
        isExplicit
    }

    public var description: String {
        switch self {
        case .launch: return "launch"
        case .manualRetry: return "manualRetry"
        case .connectionMethodChanged: return "connectionMethodChanged"
        case .networkPathChanged: return "networkPathChanged"
        case .foreground: return "foreground"
        case .presencePush: return "presencePush"
        case .backoffExpired: return "backoffExpired"
        }
    }
}
