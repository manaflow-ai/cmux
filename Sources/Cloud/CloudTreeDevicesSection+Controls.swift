import CmuxCloud
import CmuxSettingsUI

extension CloudTreeDevicesSection {
    var discoveryControl: DeviceAccessControl {
        DeviceAccessControl(.discovery, enabled: discoveryEnabled, managed: discoveryManaged, unavailable: !available)
    }

    var incomingControl: DeviceAccessControl {
        DeviceAccessControl(.incomingAccess, enabled: incomingAccessEnabled, managed: incomingAccessManaged, unavailable: !available)
    }
}
