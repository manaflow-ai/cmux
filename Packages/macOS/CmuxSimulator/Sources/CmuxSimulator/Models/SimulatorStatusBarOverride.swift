/// Optional values merged into a Simulator status bar override.
public struct SimulatorStatusBarOverride: Equatable, Sendable {
    /// Fixed time or ISO date string.
    public var time: String?
    /// Data network indicator.
    public var dataNetwork: DataNetwork?
    /// Wi-Fi state.
    public var wifiMode: ConnectionMode?
    /// Wi-Fi bars, from zero through three.
    public var wifiBars: Int?
    /// Cellular state.
    public var cellularMode: CellularMode?
    /// Cellular bars, from zero through four.
    public var cellularBars: Int?
    /// Carrier name, including an empty string to hide it.
    public var operatorName: String?
    /// Battery charging state.
    public var batteryState: BatteryState?
    /// Battery percentage, from zero through 100.
    public var batteryLevel: Int?

    /// Creates a partial status bar override.
    public init(
        time: String? = nil,
        dataNetwork: DataNetwork? = nil,
        wifiMode: ConnectionMode? = nil,
        wifiBars: Int? = nil,
        cellularMode: CellularMode? = nil,
        cellularBars: Int? = nil,
        operatorName: String? = nil,
        batteryState: BatteryState? = nil,
        batteryLevel: Int? = nil
    ) {
        self.time = time
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.operatorName = operatorName
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    /// A status bar data-network indicator.
    public typealias DataNetwork = SimulatorStatusBarDataNetwork
    /// A Wi-Fi connection mode.
    public typealias ConnectionMode = SimulatorStatusBarConnectionMode
    /// A cellular connection mode.
    public typealias CellularMode = SimulatorStatusBarCellularMode
    /// A simulated battery state.
    public typealias BatteryState = SimulatorStatusBarBatteryState
}
