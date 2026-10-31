public import Foundation

/// One phone connected to this Mac through `cmux-mobile-host`.
public struct MobileHostPhoneLink: Sendable, Equatable, Identifiable {
    /// The link's signaling session id (one per dial).
    public var sessionID: String
    /// The phone's mobile device id (its Keychain UUID).
    public var phoneDeviceID: String
    /// `webrtc` or `wireguard`.
    public var transport: String
    /// `direct`, `relay` or `turn`.
    public var path: String
    /// The WebRTC media session beside a WireGuard link, which carries the
    /// phone's browser video: its path (`direct`, `turn`), nil when none.
    public var mediaPath: String?
    /// When the app saw the link come up; set by ``MobileHostState``.
    public var since: Date?

    public var id: String { sessionID }

    public init(sessionID: String, phoneDeviceID: String, transport: String, path: String, mediaPath: String? = nil,
                since: Date? = nil) {
        self.sessionID = sessionID
        self.phoneDeviceID = phoneDeviceID
        self.transport = transport
        self.path = path
        self.mediaPath = mediaPath
        self.since = since
    }
}
