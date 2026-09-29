extension WorkspaceListNewWorkspaceMenuValue.ComputerTarget {
    enum Kind: Equatable {
        case mac(macDeviceID: String, instanceTag: String?)
        case cloud(hostID: String)
    }
}
