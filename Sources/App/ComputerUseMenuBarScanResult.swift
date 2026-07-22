import Foundation

/// Cancellation-aware background result projected onto the menu-bar snapshot.
struct ComputerUseMenuBarScanResult: Sendable {
    let rows: [ComputerUseMenuBarRow]
    let scan: ComputerUseStateScan

    /// The live agent row whose matching driver state was updated most recently.
    var mostRecentlyActiveRow: ComputerUseMenuBarRow? {
        rows
            .compactMap { row -> (row: ComputerUseMenuBarRow, lastActionAt: Date)? in
                guard let state = scan.newestStateByScopeID[row.id] else { return nil }
                return (row, state.lastActionAt)
            }
            .max { lhs, rhs in
                if lhs.lastActionAt == rhs.lastActionAt {
                    return lhs.row.id < rhs.row.id
                }
                return lhs.lastActionAt < rhs.lastActionAt
            }?
            .row
    }
}
