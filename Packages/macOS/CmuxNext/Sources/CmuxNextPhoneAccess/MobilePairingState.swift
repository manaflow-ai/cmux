public import CmuxNextMobile

/// What the Mobile Pairing page (`palette.mobileConnect`) tells the person:
/// the one step between this Mac and a phone that can reach it.
///
/// The phone is cmux on iPhone, which connects through the iPhone host
/// (`IPhoneHostService`, Settings > Mobile, `mobile.allowIPhoneConnections`).
public nonisolated enum MobilePairingState: Sendable, Equatable {
    /// No cmux account on this Mac: phones have no account to match.
    case signedOut
    /// iPhone connections (`mobile.allowIPhoneConnections`) are off.
    case accessOff
    /// Signed in and allowed; the host is starting, registering or retrying.
    case preparing
    /// The host is online: a phone on the same account can connect now.
    case ready
    /// The host could not run; the text is for logs and the page's detail line.
    case failed(String)

    /// The state for the iPhone host (`IPhoneHostService`, the bundled `cmux-mobile-host` that
    /// cmux on iPhone connects through): the account, `mobile.allowIPhoneConnections` and hostd's
    /// phase. `removedReason` is the text a removed Mac shows (the person allows it again in Settings).
    public static func resolve(signedIn: Bool, allowed: Bool, host phase: MobileHostState.Phase,
                               removedReason: String) -> MobilePairingState {
        guard signedIn else { return .signedOut }
        guard allowed else { return .accessOff }
        switch phase {
        case .online: return .ready
        case .unavailable(let reason): return .failed(reason)
        case .removed: return .failed(removedReason)
        // Starting, registering or retrying: hostd gets there by itself.
        // A refused device id: the iPhone host registers a new one by itself.
        case .off, .connecting, .waiting, .deviceIDTaken: return .preparing
        }
    }

    /// The page's name for the state (`MobilePairingStatus.state` in webviews/src/pages/mobile-pairing/types.ts).
    public var wireName: String {
        switch self {
        case .signedOut: "signedOut"
        case .accessOff: "accessOff"
        case .preparing: "preparing"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
