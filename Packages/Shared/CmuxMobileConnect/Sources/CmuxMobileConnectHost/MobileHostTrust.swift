public import CmuxLinkWebRTC
public import CmuxMobileHost
public import CmuxPairing
import Foundation

/// Every trust question the Mac's acceptors and `MobileHost` ask, answered
/// by one source (B6's `trust:<user>` mirror in the app, fixed sets in tests).
public struct MobileHostTrust: Sendable {
    public var lookup: any TrustedKeyLookup
    public var devices: any MobileTrustStore
    public var webrtc: any WebRTCAuthorizer

    public init(lookup: any TrustedKeyLookup, devices: any MobileTrustStore, webrtc: any WebRTCAuthorizer) {
        self.lookup = lookup
        self.devices = devices
        self.webrtc = webrtc
    }

    /// The trust store mirror of this Mac's account (`environment` is the API
    /// environment certs are signed for).
    public init(mirror: TrustStoreMirror, environment: String, accountUserID: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(lookup: TrustStoreKeyLookup(mirror: mirror, environment: environment, user: accountUserID, now: now),
                  devices: TrustStoreMobileDevices(mirror: mirror, accountUserID: accountUserID),
                  webrtc: TrustStoreWebRTCAuthorizer(mirror: mirror))
    }
}
