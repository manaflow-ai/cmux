public import Foundation

/// One phone connected to this Mac through `cnx-hostd`.
public struct CnxPhoneLink: Sendable, Equatable, Identifiable {
    /// The link's signaling session id (one per dial).
    public var sessionID: String
    /// The phone's cnx device id (its Keychain UUID).
    public var phoneDeviceID: String
    /// `webrtc` or `wireguard`.
    public var transport: String
    /// `direct`, `relay` or `turn`.
    public var path: String
    /// When the app saw the link come up; set by ``CnxHostState``.
    public var since: Date?

    public var id: String { sessionID }

    public init(sessionID: String, phoneDeviceID: String, transport: String, path: String, since: Date? = nil) {
        self.sessionID = sessionID
        self.phoneDeviceID = phoneDeviceID
        self.transport = transport
        self.path = path
        self.since = since
    }
}
