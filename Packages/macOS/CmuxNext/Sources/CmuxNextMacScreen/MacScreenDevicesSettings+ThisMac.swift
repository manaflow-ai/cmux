import CmuxNextDevices

extension MacScreenDevicesSettings {
    /// Every other record, each removable; this Mac's other builds (NIGHTLY, DEV, a renewed identity) say so,
    /// since Screen Sharing lists them as This Mac, not as a device (``HubDeviceList``).
    func others(_ hub: DeviceHub, me: String) -> [State.Device] {
        let thisMac = Set(hub.deviceList.thisDevice)
        return hub.otherDevices.map { other in
            var row = device(for: other, hub: hub, me: me)
            if thisMac.contains(other.id) {
                row.presence = L.t("devices.thisMacOtherBuild", "This Mac, another cmux build")
            }
            return row
        }
    }
}
