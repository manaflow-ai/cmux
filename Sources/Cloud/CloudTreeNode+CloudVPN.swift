import Foundation

extension CloudTreeNode {
    /// Whether this row is the Ports section header.
    var isPortsGroup: Bool {
        if case .portsGroup = kind { return true }
        return false
    }

    /// Whether this row is the connected empty Ports placeholder.
    var isPortsEmptyPlaceholder: Bool {
        guard case .placeholder(_, let placeholder) = kind else { return false }
        return placeholder.isEmptyPorts
    }
}
