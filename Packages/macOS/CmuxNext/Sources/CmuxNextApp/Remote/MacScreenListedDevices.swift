import CmuxNextMacScreen
import CmuxNextServer

extension AppServices {
    /// The machines `cmux device list` lists, as Screen Sharing's refusal reads them (`MacScreenActions`): a name
    /// Screen Sharing does not list but this list does says why that machine offers no screen. A person's login
    /// (no `screen` offer) is not a machine and is left out.
    func macScreenListedDevices() async -> [MacScreenListedDevice] {
        let rows = await devices.readDevices()?.devices ?? []
        return rows.compactMap { device in
            device.screen.map { MacScreenListedDevice(name: device.name, noScreenReason: $0.action == "none" ? $0.reason ?? "unknown" : nil) }
        }
    }
}
