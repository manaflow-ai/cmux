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
    public enum DataNetwork: String, Codable, CaseIterable, Hashable, Sendable {
        /// Hide the indicator.
        case hide
        /// Wi-Fi.
        case wifi
        /// 3G.
        case threeG = "3g"
        /// 4G.
        case fourG = "4g"
        /// LTE.
        case lte
        /// LTE Advanced.
        case lteAdvanced = "lte-a"
        /// LTE Plus.
        case ltePlus = "lte+"
        /// 5G.
        case fiveG = "5g"
        /// 5G Plus.
        case fiveGPlus = "5g+"
        /// 5G ultra-wideband.
        case fiveGUWB = "5g-uwb"
        /// 5G ultra-capacity.
        case fiveGUC = "5g-uc"
    }

    /// A Wi-Fi connection mode.
    public enum ConnectionMode: String, Codable, CaseIterable, Hashable, Sendable {
        /// Searching for a network.
        case searching
        /// Connection failed.
        case failed
        /// Connected.
        case active
    }

    /// A cellular connection mode.
    public enum CellularMode: String, Codable, CaseIterable, Hashable, Sendable {
        /// Cellular is unavailable on the device.
        case notSupported
        /// Searching for service.
        case searching
        /// Connection failed.
        case failed
        /// Connected.
        case active
    }

    /// A simulated battery state.
    public enum BatteryState: String, Codable, CaseIterable, Hashable, Sendable {
        /// The device is charging.
        case charging
        /// The battery is full.
        case charged
        /// The device is using battery power.
        case discharging
    }
}
