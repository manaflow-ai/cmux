import Foundation

/// Complete immutable state rendered by the computer-use status item.
struct ComputerUseMenuBarSnapshot: Equatable, Sendable {
    static let hidden = ComputerUseMenuBarSnapshot(
        rows: [],
        hasRecentStateFiles: false,
        showInMenuBar: true,
        featureEnabled: true
    )

    let rows: [ComputerUseMenuBarRow]
    let hasRecentStateFiles: Bool
    let showInMenuBar: Bool
    let featureEnabled: Bool

    var shouldShowStatusItem: Bool {
        featureEnabled && showInMenuBar && !rows.isEmpty
    }
}
