import Foundation

extension CloudMachineResourcePresentation {
    /// The localized usage detail for each capacity reading.
    enum CapacityResource: Sendable {
        case memory
        case disk

        func detail(used: String, total: String) -> String {
            switch self {
            case .memory:
                return String(localized: "cloudTree.stats.memory", defaultValue: "Mem \(used)/\(total) GB")
            case .disk:
                return String(localized: "cloudTree.stats.disk", defaultValue: "Disk \(used)/\(total) GB")
            }
        }
    }
}
