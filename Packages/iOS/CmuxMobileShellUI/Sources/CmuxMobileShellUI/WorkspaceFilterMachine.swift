import CmuxMobilePairedMac
import Foundation

/// A machine the workspace list can be filtered to.
struct WorkspaceFilterMachine: Identifiable, Hashable {
    let id: String
    let macDeviceID: String
    let instanceTag: String?
    let name: String
    let buildLabel: String?
}

extension WorkspaceFilterMachine {
    init(
        id: String,
        namesByID: [String: String],
        buildLabel: String?,
        fallbackName: String
    ) {
        let identity = MobilePairedMac.pairingIdentity(from: id)
        self.id = id
        self.macDeviceID = identity.macDeviceID
        self.instanceTag = identity.instanceTag
        self.name = namesByID[id] ?? namesByID[identity.macDeviceID] ?? fallbackName
        self.buildLabel = buildLabel
    }
}

extension Array where Element == WorkspaceFilterMachine {
    func sortedForMenuDisplay() -> [WorkspaceFilterMachine] {
        sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            let buildLabelOrder = (lhs.buildLabel ?? "").localizedStandardCompare(rhs.buildLabel ?? "")
            if buildLabelOrder != .orderedSame {
                return buildLabelOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
