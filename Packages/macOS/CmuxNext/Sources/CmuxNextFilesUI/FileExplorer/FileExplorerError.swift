package import Foundation

/// Why a file explorer action did not run; ``reason`` is shown to people and callers.
package nonisolated enum FileExplorerError: Error, Equatable, Sendable {
    /// No row is selected (or the selected item left the tree).
    case noSelection
    /// cmux has no viewer for this item (`name`).
    case notViewable(String)
    /// No app matches what Open With named.
    case noSuchApp(String)
    /// The app would not open the item.
    case openFailed(String)

    package var reason: String {
        switch self {
        case .noSelection: FileExplorerStrings.noSelection
        case .notViewable(let name): FileExplorerStrings.notViewable(name)
        case .noSuchApp(let app): FileExplorerStrings.noSuchApp(app)
        case .openFailed(let name): FileExplorerStrings.openFailed(name)
        }
    }
}
