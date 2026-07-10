import CmuxSimulator

extension SimulatorPaneCoordinator {
    func selectActionHistory(deviceID: String?) {
        if let selectedDeviceID {
            actionHistoryByDeviceID[selectedDeviceID] = Array(
                actionLog.prefix(Self.maximumActionLogCount)
            )
        }
        actionLog = deviceID.flatMap { actionHistoryByDeviceID[$0] } ?? []
    }
}
