import SwiftUI

/// Native menu items for independent Mac discovery and incoming access preferences.
public struct ComputerAccessMenuItems: View {
    private let discoveryEnabled: Bool
    private let incomingAccessEnabled: Bool
    private let discoveryManaged: Bool
    private let incomingAccessManaged: Bool
    private let identifierPrefix: String
    private let setDiscovery: (Bool) -> Void
    private let setIncomingAccess: (Bool) -> Void

    /// Creates menu content from a preference snapshot and the owner's mutation actions.
    ///
    /// - Parameters:
    ///   - discoveryEnabled: Whether this Mac discovers other account Macs.
    ///   - incomingAccessEnabled: Whether other devices may connect to this Mac.
    ///   - discoveryManaged: Whether administrator policy disables discovery.
    ///   - incomingAccessManaged: Whether administrator policy disables incoming access.
    ///   - identifierPrefix: Accessibility namespace for the containing surface.
    ///   - setDiscovery: Persists the selected discovery preference.
    ///   - setIncomingAccess: Persists the selected incoming access preference.
    public init(
        discoveryEnabled: Bool,
        incomingAccessEnabled: Bool,
        discoveryManaged: Bool,
        incomingAccessManaged: Bool,
        identifierPrefix: String,
        setDiscovery: @escaping (Bool) -> Void,
        setIncomingAccess: @escaping (Bool) -> Void
    ) {
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.discoveryManaged = discoveryManaged
        self.incomingAccessManaged = incomingAccessManaged
        self.identifierPrefix = identifierPrefix
        self.setDiscovery = setDiscovery
        self.setIncomingAccess = setIncomingAccess
    }

    /// The two checkmarked preferences, with details available as help text.
    public var body: some View {
        let incoming = DeviceAccessControl(.incomingAccess, enabled: incomingAccessEnabled, managed: incomingAccessManaged)
        let discovery = DeviceAccessControl(.discovery, enabled: discoveryEnabled, managed: discoveryManaged)
        Toggle(incoming.title, isOn: Binding(
            get: { incoming.isOn },
            set: setIncomingAccess
        ))
        .disabled(!incoming.isEnabled)
        .help(incoming.help)
        .accessibilityLabel(incoming.title)
        .accessibilityIdentifier(identifierPrefix + "IncomingAccessToggle")
        Toggle(discovery.title, isOn: Binding(
            get: { discovery.isOn },
            set: setDiscovery
        ))
        .disabled(!discovery.isEnabled)
        .help(discovery.help)
        .accessibilityLabel(discovery.title)
        .accessibilityIdentifier(identifierPrefix + "DiscoveryToggle")
    }
}
