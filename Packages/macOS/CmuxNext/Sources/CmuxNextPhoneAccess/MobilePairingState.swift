public import CmuxNextMobile

/// What the Mobile Pairing page (`palette.mobileConnect`) tells the person:
/// the one step between this Mac and a phone that can reach it.
///
/// Pairing is the v2 same-account gate (plans/cmux-next/cloud-ios.md 2.2):
/// a phone signed in to the same cmux account finds this Mac once phone
/// access is on and the listener is up. The page adds a QR code with this
/// Mac's attach URL so a phone camera opens cmux on this Mac directly.
public nonisolated enum MobilePairingState: Sendable, Equatable {
    /// No cmux account on this Mac: phones have no account to match.
    case signedOut
    /// Settings > Accounts > Phone Access (`phone.allowConnections`) is off.
    case accessOff
    /// Signed in and allowed; the listener is provisioning or finding a relay.
    case preparing
    /// The listener is up: a phone on the same account can connect now.
    case ready
    /// The listener could not start; the text is for logs and the page's detail line.
    case failed(String)

    /// The state for the account, the setting and the listener's phase
    /// (nil while no listener exists yet).
    public static func resolve(signedIn: Bool, allowed: Bool, phase: MobileIrxHost.Phase?) -> MobilePairingState {
        .signedOut
    }

    /// The page's name for the state (`MobilePairingStatus.state` in webviews/src/pages/mobile-pairing/types.ts).
    public var wireName: String { "signedOut" }
}
