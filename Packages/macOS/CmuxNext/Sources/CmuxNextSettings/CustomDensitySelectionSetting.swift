/// `appearance.customDensity` in cmux.json: the id of the custom density in use
/// (`appearance.customDensities`). When it names one, it wins over `appearance.density`, which
/// stays a portable built-in choice; picking a built-in removes it
/// (plans/cmux-next/density-DESIGN.md).
public nonisolated struct CustomDensitySelectionSetting: Sendable {
    /// The key's path.
    public let configPath = ["appearance", "customDensity"]

    public init() {}
}
