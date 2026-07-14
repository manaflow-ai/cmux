import CmuxCore
import Foundation

/// Parsed `lsof` output plus the scope of evidence that could not be inspected.
struct PortLsofScanResult: Sendable {
    let values: [Int: Set<Int>]
    let globallyComplete: Bool
    let incompletePIDs: Set<Int>

    var completeness: PortScanCompleteness {
        globallyComplete && incompletePIDs.isEmpty ? .complete : .incomplete
    }

    func completeness(for pids: Set<Int>) -> PortScanCompleteness {
        guard !pids.isEmpty else { return .complete }
        return globallyComplete && incompletePIDs.isDisjoint(with: pids)
            ? .complete
            : .incomplete
    }
}
