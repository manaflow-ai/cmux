import CmuxSettings
import Testing
@testable import CmuxSettingsUI

struct DeviceAccessControlTests {
    @Test("Device actions and accessibility labels describe the next state", arguments: [false, true])
    func labels(enabled: Bool) {
        let incoming = DeviceAccessControl(.incomingAccess, enabled: enabled, managed: false)
        let discovery = DeviceAccessControl(.discovery, enabled: enabled, managed: false)
        #expect(incoming.title == (enabled ? "Hide this Mac from My Devices" : "Make this Mac discoverable"))
        #expect(discovery.title == (enabled ? "Stop discovering other Macs" : "Discover other Macs"))
        #expect(incoming.isOn == enabled)
        #expect(discovery.isOn == enabled)
        #expect(incoming.isEnabled && discovery.isEnabled)
    }

    @Test("Unavailable or managed controls remain off with their enable action labels",
          arguments: [false, true], [DevicesAccessCoordinator.Preference.incomingAccess, .discovery])
    func gates(managed: Bool, preference: DevicesAccessCoordinator.Preference) {
        let control = DeviceAccessControl(preference, enabled: true, managed: managed, unavailable: !managed)
        #expect(!control.isOn)
        #expect(!control.isEnabled)
        #expect(control.title == (preference == .incomingAccess ? "Make this Mac discoverable" : "Discover other Macs"))
        if managed { #expect(control.help == "Disabled by your administrator.") }
    }
}
