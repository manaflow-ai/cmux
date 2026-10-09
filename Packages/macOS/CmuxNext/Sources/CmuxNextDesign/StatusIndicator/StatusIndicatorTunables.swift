public import Foundation

/// Debug Settings tunables for status indicators (section "Status
/// Indicators"). `style` overrides `appearance.statusIndicator.style` so
/// the prototype variants can be compared live without editing cmux.json.
public nonisolated enum StatusIndicatorTunables {
    public static let style = Tunable<StatusIndicatorStyle>.choice(
        "status.indicator.style", .status, "Style override",
        help: "Overrides appearance.statusIndicator.style everywhere: arc, native (NSProgressIndicator), dot, braille, none.",
        default: .arc, code: "StatusIndicatorSettings.style")
    public static let arcLength = Tunable<Double>.number(
        "status.indicator.arcLength", .status, "Arc length", help: "Share of the circle the indeterminate arc covers.",
        default: 0.72, range: 0.2...0.95, step: 0.01, unit: .fraction, code: "StatusIndicatorTunables.arcLength")
    public static let trackOpacity = Tunable<Double>.number(
        "status.indicator.trackOpacity", .status, "Ring track opacity", help: "Opacity of the full circle behind determinate progress.",
        default: 0.22, range: 0...1, step: 0.01, unit: .fraction, code: "StatusIndicatorTunables.trackOpacity")
    public static let dotScale = Tunable<Double>.number(
        "status.indicator.dotScale", .status, "Dot size", help: "Dot diameter as a share of the indicator slot (busy dot, waiting, error).",
        default: 0.5, range: 0.2...1, step: 0.05, unit: .fraction, code: "StatusIndicatorTunables.dotScale")
    public static let pulseLow = Tunable<Double>.number(
        "status.indicator.pulseLow", .status, "Pulse low opacity", help: "Lowest opacity of the pulsing dot.",
        default: 0.35, range: 0...1, step: 0.05, unit: .fraction, code: "StatusIndicatorTunables.pulseLow")
    public static let nativeSteps = Tunable<Double>.number(
        "status.indicator.nativeSteps", .status, "Native spinner steps", help: "Discrete rotation steps per turn of the native spinner (its spoke count).",
        default: 8, range: 4...24, step: 1, unit: .count, code: "StatusIndicatorTunables.nativeSteps")

    public static var all: [TunableDescriptor] {
        [style.descriptor, arcLength.descriptor, trackOpacity.descriptor, dotScale.descriptor, pulseLow.descriptor, nativeSteps.descriptor,
         StatusIconSet.tunable.descriptor]
    }
}
