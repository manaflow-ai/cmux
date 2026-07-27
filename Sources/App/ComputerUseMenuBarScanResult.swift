import Foundation

/// Cancellation-aware background result projected onto the menu-bar snapshot.
struct ComputerUseMenuBarScanResult: Sendable {
    let rows: [ComputerUseMenuBarRow]
    let scan: ComputerUseStateScan

    /// The live agent row whose matching driver state was updated most recently.
    var mostRecentlyActiveRow: ComputerUseMenuBarRow? {
        mostRecentlyActive { _, _ in true }?.row
    }

    func mostRecentlyActive(
        where isEligible: (
            ComputerUseMenuBarRow,
            ComputerUseDriverState
        ) -> Bool
    ) -> (row: ComputerUseMenuBarRow, state: ComputerUseDriverState)? {
        rows
            .compactMap { row -> (
                row: ComputerUseMenuBarRow,
                state: ComputerUseDriverState
            )? in
                guard
                    let state = scan.newestStateByScopeID[row.id],
                    isEligible(row, state)
                else {
                    return nil
                }
                return (row, state)
            }
            .max { lhs, rhs in
                if lhs.state.lastActionAt == rhs.state.lastActionAt {
                    return lhs.row.id < rhs.row.id
                }
                return lhs.state.lastActionAt < rhs.state.lastActionAt
            }
    }
}
