import CmuxNextDevices
import CmuxNextWakeups

extension MacScreenPages {
    /// What a device tab shows of its device.
    struct DeviceLabel: Equatable {
        var id: String
        var name: String
        var online: Bool
    }

    /// Device tabs take their device's name from the hub (renames show live). A service: the names are
    /// saved and hidden tabs' titles change too. `visible`: a hub push (another device's rename) changes
    /// what strips show; a rename here flushes as the rest of that action.
    func watchDeviceNames() {
        namesWatch?.cancel()
        namesWatch = nil
        guard let hub else { return }
        namesWatch = ServiceObservation(.visible, owner: "MacScreenPages.deviceNames", on: mainWork) {
            hub.devices.map { DeviceLabel(id: $0.id, name: $0.name, online: $0.online) }
        } apply: { [weak self] labels in
            self?.deviceLabelsChanged(labels, connected: hub.connection == .connected)
        }
    }

    /// `labels` are the hub's devices now. `connected`: this Mac's own link is up, so the hub's word on a host is current.
    private func deviceLabelsChanged(_ labels: [DeviceLabel], connected: Bool) {
        let byID = Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if store.rememberDeviceNames(byID.mapValues(\.name)) { refreshDeviceTitles() }
        if connected {
            for viewer in hubViewers { if let label = byID[viewer.deviceID] { viewer.hostOnlineChanged(label.online) } }
        }
        for tab in tabs.values {
            guard let id = tab.record.deviceID, let name = byID[id]?.name, !name.isEmpty, tab.pane?.model.name != name else { continue }
            tab.rename(name)
            events.titleChanged(tab.key)
        }
    }

    /// The name of device `id`: the hub's, else the last one seen, else "Mac".
    func deviceName(_ id: String) -> String {
        hub?.devices.first { $0.id == id }?.name ?? store.deviceNames[id] ?? L.t("macScreen.hub.unknownDevice", "Mac")
    }
}
