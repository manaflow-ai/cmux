import Foundation

/// Cancellation-aware background result projected onto the menu-bar snapshot.
struct ComputerUseMenuBarScanResult: Sendable {
    let rows: [ComputerUseMenuBarRow]
    let scan: ComputerUseStateScan
    let capableSessionIDs: Set<String>
}
