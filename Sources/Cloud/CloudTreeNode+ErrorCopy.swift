import Foundation

extension CloudTreeNode {
    var errorCopyText: String? {
        switch kind {
        case .machine(let machine, let info):
            if let error = info?.linkError, !error.isEmpty {
                return "\(machine.displayName)\n\(error)\nmachine=\(machine.id)"
            }
            if case .attention(let error) = machine.activity {
                return "\(machine.displayName)\n\(error)\nmachine=\(machine.id)"
            }
            return nil
        case .placeholder(let machine, let placeholder) where placeholder.style == .error:
            return "\(placeholder.text)\nmachine=\(machine.rawValue)"
        default:
            return nil
        }
    }
}
