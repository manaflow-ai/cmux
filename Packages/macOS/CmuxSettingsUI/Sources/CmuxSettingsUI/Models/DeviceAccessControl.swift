import CmuxSettings
import Foundation

/// The effective state and action label used by every device preference control.
public struct DeviceAccessControl {
    private let preference: DevicesAccessCoordinator.Preference
    private let managed: Bool
    /// Whether the preference is on after applying availability and managed policy.
    public let isOn: Bool
    /// Whether the control may request a change.
    public let isEnabled: Bool

    /// Creates a presentation value from the owner's preference snapshot.
    /// - Parameters:
    ///   - preference: The independent preference this control changes.
    ///   - enabled: Its persisted value.
    ///   - managed: Whether administrator policy disables this preference.
    ///   - unavailable: Whether Cloud availability disables My Devices.
    public init(
        _ preference: DevicesAccessCoordinator.Preference,
        enabled: Bool,
        managed: Bool,
        unavailable: Bool = false
    ) {
        self.preference = preference
        self.managed = managed
        isEnabled = !managed && !unavailable
        isOn = enabled && isEnabled
    }

    /// The next action, also used as the accessibility label.
    public var title: String {
        switch preference {
        case .discovery:
            return isOn
                ? String(localized: "devices.discovery.stop", defaultValue: "Stop discovering other Macs", bundle: .module)
                : String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs")
        case .incomingAccess:
            return isOn
                ? String(localized: "devices.incoming.hide", defaultValue: "Hide this Mac from My Devices", bundle: .module)
                : String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable")
        }
    }

    /// Explains policy or the effects of this independent preference.
    public var help: String {
        if managed {
            return String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
        }
        switch preference {
        case .discovery:
            return String(localized: "devices.discovery.help", defaultValue: "Find and connect to other Macs signed in to your account. Turning this off disconnects their panes without closing their terminals.")
        case .incomingAccess:
            return String(localized: "devices.incoming.help", defaultValue: "Turning this off removes this Mac from discovery and disconnects incoming sessions. You can still connect to your other Macs.")
        }
    }
}
