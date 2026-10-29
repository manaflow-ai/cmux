import CmuxSimulator

extension SimulatorPaneCoordinator {
    func selectActionHistory(deviceID: String?) {
        if let selectedDeviceID,
           devices.contains(where: { $0.id == selectedDeviceID }) {
            actionHistoryByDeviceID[selectedDeviceID] = Array(
                actionLog.prefix(Self.maximumActionLogCount)
            )
        }
        actionLog = deviceID.flatMap { actionHistoryByDeviceID[$0] } ?? []
    }

    func pruneActionHistory(keeping deviceIDs: Set<String>) {
        actionHistoryByDeviceID = actionHistoryByDeviceID.filter { deviceIDs.contains($0.key) }
    }
}
