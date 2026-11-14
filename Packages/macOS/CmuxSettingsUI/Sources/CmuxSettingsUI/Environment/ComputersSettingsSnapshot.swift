import CmuxSettings
import Foundation

public struct ComputersSettingsSnapshot: Equatable, Sendable {
    public struct Computer: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let tag: String?
        public let isPaired: Bool
        public let isOnline: Bool?
        /// Whether this physical Mac is hidden in the sidebar on this installation.
        public let isHidden: Bool
        /// Whether an authenticated remote-control session is established.
        public let isConnected: Bool

        public init(id: String, title: String, tag: String?, isPaired: Bool, isOnline: Bool?, isHidden: Bool = false, isConnected: Bool = false) {
            self.id = id
            self.title = title
            self.tag = tag
            self.isPaired = isPaired
            self.isOnline = isOnline
            self.isHidden = isHidden
            self.isConnected = isConnected
        }
    }

    public var computers: [Computer]
    public var isSignedIn: Bool
    public var error: String?
    /// Whether this installation discovers other Macs.
    public var discoveryEnabled: Bool
    /// Whether this Mac permits incoming remote sessions.
    public var incomingAccessEnabled: Bool
    /// Why the account's Macs cannot be listed at all (Cloud Machines is off,
    /// unavailable, or disabled by policy), or `nil` when they can.
    public var unavailableMessage: String?
    /// Whether the directory read behind ``computers`` has finished.
    /// Defaults to discovering so the first frame cannot say the account
    /// has no Macs before that read exists.
    public var discoveryPhase: DeviceListDiscoveryPhase

    public init(
        computers: [Computer] = [], isSignedIn: Bool = false, error: String? = nil,
        discoveryEnabled: Bool = false, incomingAccessEnabled: Bool = false,
        unavailableMessage: String? = nil,
        discoveryPhase: DeviceListDiscoveryPhase = .discovering
    ) {
        self.computers = computers
        self.isSignedIn = isSignedIn
        self.error = error
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.unavailableMessage = unavailableMessage
        self.discoveryPhase = discoveryPhase
    }
}
