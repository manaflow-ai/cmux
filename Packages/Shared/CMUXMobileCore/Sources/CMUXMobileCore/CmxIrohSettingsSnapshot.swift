public import Foundation

/// Immutable, credential-free state rendered by Iroh settings on macOS and iOS.
public struct CmxIrohSettingsSnapshot: Equatable, Sendable {
    public enum RuntimeStatus: Equatable, Sendable {
        case inactive
        case starting
        /// Endpoint is active, but no live peer path is currently attributable.
        case active
        case direct
        case relayed(provider: String, region: String)
        case privateNetwork(displayName: String)
        case degraded

        /// Creates an active runtime status from one coordinate-free path.
        ///
        /// - Parameter path: The redacted selected transport path.
        public init(activePath path: CmxIrohSelectedTransportPath) {
            switch path {
            case .unavailable:
                self = .active
            case .direct:
                self = .direct
            case .privateNetwork:
                self = .privateNetwork(displayName: "")
            case let .managedRelay(provider, region):
                self = .relayed(provider: provider, region: region)
            case let .customRelay(_, provider, region):
                self = .relayed(provider: provider, region: region)
            }
        }
    }

    public enum PolicySource: Equatable, Sendable {
        case server
        case cached
        case unavailable
    }

    public enum CredentialState: Equatable, Sendable {
        case notRequired
        case configured
        case missing
        case unavailable
    }

    public struct ManagedRelay: Identifiable, Equatable, Sendable {
        public let id: String
        public let provider: String
        public let region: String
        public let url: String
        public let isSelected: Bool

        public init(id: String, provider: String, region: String, url: String, isSelected: Bool) {
            self.id = id
            self.provider = provider
            self.region = region
            self.url = url
            self.isSelected = isSelected
        }
    }

    public struct CustomRelay: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let provider: String
        public let region: String
        public let url: String
        public let authMode: CmxIrohCustomRelayCredentialMode
        public let credentialState: CredentialState

        public init(
            id: String,
            displayName: String,
            provider: String,
            region: String,
            url: String,
            authMode: CmxIrohCustomRelayCredentialMode,
            credentialState: CredentialState
        ) {
            self.id = id
            self.displayName = displayName
            self.provider = provider
            self.region = region
            self.url = url
            self.authMode = authMode
            self.credentialState = credentialState
        }
    }

    /// A broker-authenticated Mac available for device-local path settings.
    public struct PrivateNetworkMac: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    /// One device-local, per-Mac custom private-path configuration.
    public struct CustomPrivateNetwork: Identifiable, Equatable, Sendable {
        public var id: String { macDeviceID }
        public let macDeviceID: String
        public let macDisplayName: String
        public let addresses: [String]
        public let isEnabled: Bool

        public init(
            macDeviceID: String,
            macDisplayName: String,
            addresses: [String],
            isEnabled: Bool
        ) {
            self.macDeviceID = macDeviceID
            self.macDisplayName = macDisplayName
            self.addresses = addresses
            self.isEnabled = isEnabled
        }
    }

    public let runtimeStatus: RuntimeStatus
    /// Redacted selected-path attribution, independent from lifecycle status.
    public let selectedTransportPath: CmxIrohSelectedTransportPath
    public let preference: CmxIrohRelayPreferenceDraft
    public let managedRelays: [ManagedRelay]
    public let customRelays: [CustomRelay]
    public let privateNetworkMacs: [PrivateNetworkMac]
    public let customPrivateNetworks: [CustomPrivateNetwork]
    public let policySource: PolicySource
    public let policySequence: Int64?
    public let policyExpiresAt: Date?
    public let staleRelayIDs: Set<String>
    public let failureDescription: String?
    /// Debug-only path constraint, or `nil` when the current app cannot control it.
    public let debugTransportVerificationMode: CmxIrohTransportVerificationMode?

    /// Compatibility projection for the existing macOS relay-only toggle.
    public var debugRelayOnlyEnabled: Bool? {
        debugTransportVerificationMode.map { $0 == .relayOnly }
    }

    public init(
        runtimeStatus: RuntimeStatus,
        selectedTransportPath: CmxIrohSelectedTransportPath = .unavailable,
        preference: CmxIrohRelayPreferenceDraft,
        managedRelays: [ManagedRelay],
        customRelays: [CustomRelay],
        privateNetworkMacs: [PrivateNetworkMac] = [],
        customPrivateNetworks: [CustomPrivateNetwork] = [],
        policySource: PolicySource,
        policySequence: Int64? = nil,
        policyExpiresAt: Date? = nil,
        staleRelayIDs: Set<String> = [],
        failureDescription: String? = nil,
        debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
    ) {
        self.runtimeStatus = runtimeStatus
        self.selectedTransportPath = selectedTransportPath
        self.preference = preference
        self.managedRelays = managedRelays
        self.customRelays = customRelays
        self.privateNetworkMacs = privateNetworkMacs
        self.customPrivateNetworks = customPrivateNetworks
        self.policySource = policySource
        self.policySequence = policySequence
        self.policyExpiresAt = policyExpiresAt
        self.staleRelayIDs = staleRelayIDs
        self.failureDescription = failureDescription
        self.debugTransportVerificationMode = debugTransportVerificationMode
    }

    public static let unavailable = CmxIrohSettingsSnapshot(
        runtimeStatus: .inactive,
        preference: .automatic,
        managedRelays: [],
        customRelays: [],
        policySource: .unavailable
    )
}
