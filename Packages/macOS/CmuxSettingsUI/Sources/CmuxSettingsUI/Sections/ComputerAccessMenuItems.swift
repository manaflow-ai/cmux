import SwiftUI

/// Native menu items for independent Mac discovery and incoming access preferences.
public struct ComputerAccessMenuItems: View {
    private let discoveryEnabled: Bool
    private let incomingAccessEnabled: Bool
    private let discoveryManaged: Bool
    private let incomingAccessManaged: Bool
    private let discoveryAvailable: Bool
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
    ///   - discoveryAvailable: Whether the My Devices feature is enabled.
    ///   - identifierPrefix: Accessibility namespace for the containing surface.
    ///   - setDiscovery: Persists the selected discovery preference.
    ///   - setIncomingAccess: Persists the selected incoming access preference.
    public init(
        discoveryEnabled: Bool,
        incomingAccessEnabled: Bool,
        discoveryManaged: Bool,
        incomingAccessManaged: Bool,
        discoveryAvailable: Bool = true,
        identifierPrefix: String,
        setDiscovery: @escaping (Bool) -> Void,
        setIncomingAccess: @escaping (Bool) -> Void
    ) {
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.discoveryManaged = discoveryManaged
        self.incomingAccessManaged = incomingAccessManaged
        self.discoveryAvailable = discoveryAvailable
        self.identifierPrefix = identifierPrefix
        self.setDiscovery = setDiscovery
        self.setIncomingAccess = setIncomingAccess
    }

    /// The two checkmarked preferences, with details available as help text.
    public var body: some View {
        Toggle(String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"), isOn: Binding(
            get: { discoveryEnabled && discoveryAvailable && !discoveryManaged },
            set: setDiscovery
        ))
        .disabled(discoveryManaged || !discoveryAvailable)
        .help(discoveryManaged
            ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
            : String(localized: "devices.discovery.help", defaultValue: "Find and connect to other Macs signed in to your account. Turning this off disconnects their panes without closing their terminals."))
        .accessibilityIdentifier(identifierPrefix + "DiscoveryToggle")
        Toggle(String(localized: "devices.incoming.toggle", defaultValue: "Allow access to this Mac"), isOn: Binding(
            get: { incomingAccessEnabled && !incomingAccessManaged },
            set: setIncomingAccess
        ))
        .disabled(incomingAccessManaged)
        .help(incomingAccessManaged
            ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
            : String(localized: "devices.incoming.help", defaultValue: "Turning this off removes this Mac from discovery and disconnects incoming sessions. You can still connect to your other Macs."))
        .accessibilityIdentifier(identifierPrefix + "IncomingAccessToggle")
    }
}
