/// What a control of the Add Device card does. One path for the click and the key.
public nonisolated enum AddDeviceAction: Equatable, Sendable {
    /// Add a computer the network lists (way ``AddDeviceWay/network``).
    case pick(DeviceListing.Available)
    /// Add Machine with an empty field, for a computer the network does not list.
    case otherComputer
    /// Create a cmux Cloud VM (the app's New Cloud Machine; sign-in first when signed out).
    case newCloudMachine
    /// Open the code field (way ``AddDeviceWay/code``).
    case enterCode
    /// Copy the setup line of the chosen platform.
    case installTailscale
    case copyLine
    /// Copy the one-line join (way ``AddDeviceWay/joinLine``), concealed from clipboard managers.
    case copyJoinLine
    /// Mint the first join line, with the name typed (a line is made only on this click).
    case makeJoinLine
    /// Mint a new join line (an expired or failed one is never shown again).
    case newJoinLine
    /// The joined machine's row in the Machines sidebar.
    case showMachines
    case done
    case cancel
}
