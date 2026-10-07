public import CmuxLinkWebRTC
public import CmuxPairing

/// The seam the app fills once the Mac has a backend install principal
/// (d1-terminal-ux.md section 2, Mac wiring): the phone link needs the
/// enrolled host id, an install token for `/v1/wire/user` and
/// `/v1/wire/host/<host>`, and the install key that signs this Mac's
/// `direct` link certificate. The irx host's Stack session is not enough.
public protocol MobileLinkHostAccount: Sendable {
    func principal() async throws -> MobileLinkHostPrincipal
    /// A current install token (the control-plane bearer).
    func installToken() async throws -> String
    /// Signs this Mac's link certificates with the install key; nil skips
    /// publishing (phones then cannot pin the Mac's `direct` key).
    var installSigner: (any LinkKeySigning)? { get }
    /// The same install key as a synchronous signer for WebRTC fingerprint
    /// bindings (phones pin the host's install key); nil disables WebRTC.
    var webrtcIdentity: (any WebRTCIdentity)? { get }
    /// False once the user signed out or switched account; the host stops.
    func isCurrent() async -> Bool
}
