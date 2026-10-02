import Foundation

/// One of the machine details shown as a row of tabs under a Cloud machine's
/// workspaces. Each tab stands for the group the tree used to show as its own
/// row (Ports, Terminals, Resources).
enum CloudTreeMachineDetailTab: String, CaseIterable, Equatable {
    case ports
    case terminals
    case resources

    var title: String {
        switch self {
        case .ports: return String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        case .terminals: return String(localized: "cloudTree.group.terminals", defaultValue: "Terminals")
        case .resources: return String(localized: "cloudTree.group.resources", defaultValue: "Resources")
        }
    }

    var accessibilityIdentifier: String { "CloudMachineDetailTab.\(rawValue)" }
}
