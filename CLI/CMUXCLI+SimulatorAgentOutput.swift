extension CMUXCLI {
    enum SimulatorAgentOutput: Equatable {
        case completed
        case eventLog
        case cameraStatus
        case permissionsList
        case permissionsUpdated(action: String, service: String, bundleIdentifier: String)
        case interfaceStatus
        case interfaceValue(option: String)
        case interfaceUpdated(option: String)
        case accessibility
        case foregroundApplication
    }
}
