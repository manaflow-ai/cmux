/// What a control of the Add Device card does. One path for the click and the key.
public nonisolated enum AddDeviceAction: Equatable, Sendable {
    /// Add a computer the network lists (way ``AddDeviceWay/network``).
    case pick(DeviceListing.Available)
    /// Add Machine with an empty field, for a computer the network does not list.
    case otherComputer
    /// Open the code field (way ``AddDeviceWay/code``).
    case enterCode
    /// Copy the setup line of the chosen platform.
    case copyLine
    case done
    case cancel
}
