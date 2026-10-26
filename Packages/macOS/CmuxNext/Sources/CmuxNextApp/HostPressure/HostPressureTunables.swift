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

/// The indicator's look (design versions for the gallery; `gauge` is the default).
enum HostPressureIndicatorStyle: String, Sendable, CaseIterable, TunableChoice {
    case gauge, triangle, load

    var tunableTitle: String {
        switch self {
        case .gauge: "Gauge, a triangle at critical"
        case .triangle: "Triangle at both levels"
        case .load: "Gauge with the load against its limit"
        }
    }
}

/// Debug Settings of the host pressure indicator (DEV and NIGHTLY; Release and RC never activate
/// the store, so they keep the defaults). English developer text, as every Debug Settings section.
enum HostPressureTunables {
    static let section = TunableSection(id: "hostPressure", title: "Host Pressure", symbol: "gauge.with.dots.needle.67percent", order: 50)

    /// The developer's local override of the feature `hostPressure`
    /// (`schemas/features/features.d/hostPressure.json`, which `replaces` this key, off on every
    /// channel, cmux#22662: a new dev surface ships off). Nothing reads it here: the launch's
    /// feature ladder takes it from the Debug Settings file as step 3 (`FeatureLaunchLocalOverrides`;
    /// DEV and NIGHTLY, under managed policy and `CMUX_DISABLE_FEATURES`/`CMUX_ENABLE_FEATURES`), so a
    /// change applies at the next launch. Off: no indicator, no service, no timer and no sampling.
    /// On: each visible window's indicator subscribes, and the app's one monitor reads the host
    /// every 15 s while at least one window can be seen.
    static let enabled = Tunable<Bool>.toggle(
        "hostPressure.enabled", section, "Show the host pressure indicator",
        help: "Overrides the feature hostPressure (off by default) at the next launch. On: a still gauge after the toolbar band when this Mac is busy or overloaded, with a popover of the load, acpmux's reasons and its busiest sessions. It reads the host every 15 seconds only while a window can be seen. Off: no indicator, no timer and no reads.",
        default: false, code: "HostPressureTunables.enabled")

    static let force = Tunable<HostPressureForce>.choice(
        "hostPressure.force", section, "Force level",
        help: "With the indicator on, shows it at this level with sample numbers (the cosmic-gray incident: load 146 on 12 performance cores, memory pressure warn, swap growing), whatever the host is at. Off follows the host.",
        default: .off, code: "HostPressureTunables.force")

    static let style = Tunable<HostPressureIndicatorStyle>.choice(
        "hostPressure.style", section, "Indicator look",
        help: "The top-row indicator's design version: a gauge (a triangle at critical; the default), a triangle at both levels, or the gauge with the load against its limit (9.6 / 12).",
        default: .gauge, code: "HostPressureTunables.style")

    /// The critical banner, a new dev surface: off by default (cmux#22662), and inert while off.
    static let banner = Tunable<Bool>.toggle(
        "hostPressure.banner", section, "Critical banner",
        help: "Off by default. With the indicator on, at critical a banner names acpmux's reasons and offers Show Details. Off: the indicator only.",
        default: false, code: "HostPressureTunables.banner")

    static var all: [TunableDescriptor] { [enabled.descriptor, force.descriptor, style.descriptor, banner.descriptor] }
}
