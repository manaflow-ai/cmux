/// A Simulator status bar data-network indicator.
public enum SimulatorStatusBarDataNetwork: String, Codable, CaseIterable, Hashable, Sendable {
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
