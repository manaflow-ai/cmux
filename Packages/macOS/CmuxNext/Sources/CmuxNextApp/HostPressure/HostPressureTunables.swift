import CmuxNextDesign
import CmuxNextHostPressure

/// What Debug Settings shows instead of the host's real level (captures, design review).
enum HostPressureForce: String, Sendable, CaseIterable, TunableChoice {
    case off, warning, critical

    var tunableTitle: String {
        switch self {
        case .off: "Off (the host's real level)"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var level: HostPressureLevel? {
        switch self {
        case .off: nil
        case .warning: .warning
        case .critical: .critical
        }
    }
}

/// Debug Settings of the host pressure indicator (DEV and NIGHTLY; Release and RC never activate
/// the store, so they keep the defaults). English developer text, as every Debug Settings section.
enum HostPressureTunables {
    static let section = TunableSection(id: "hostPressure", title: "Host Pressure", symbol: "gauge.with.dots.needle.67percent", order: 50)

    static let force = Tunable<HostPressureForce>.choice(
        "hostPressure.force", section, "Force level",
        help: "Shows the indicator at this level with sample numbers (the cosmic-gray incident: load 146 on 12 performance cores, memory pressure warn, swap growing), whatever the host is at. Off follows the host.",
        default: .off, code: "HostPressureTunables.force")

    static var all: [TunableDescriptor] { [force.descriptor] }
}
