import Foundation

/// A machine the workspace list can be filtered to.
struct WorkspaceFilterMachine: Identifiable, Hashable {
    let id: String
    let name: String
}

extension WorkspaceFilterMachine {
    init(id: String, namesByID: [String: String], fallbackName: String) {
        self.id = id
        self.name = namesByID[id] ?? fallbackName
    }
}

extension Array where Element == WorkspaceFilterMachine {
    func sortedForMenuDisplay() -> [WorkspaceFilterMachine] {
        sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
