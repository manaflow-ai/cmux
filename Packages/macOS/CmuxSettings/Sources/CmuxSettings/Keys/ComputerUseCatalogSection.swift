import Foundation

/// Settings under the dotted-id prefix `computerUse.*`.
public struct ComputerUseCatalogSection: SettingCatalogSection {
    /// Optional path to a development `cua-driver` binary.
    public let driverPath = JSONKey<String>(
        id: "computerUse.driverPath",
        defaultValue: ""
    )

    public init() {}
}
