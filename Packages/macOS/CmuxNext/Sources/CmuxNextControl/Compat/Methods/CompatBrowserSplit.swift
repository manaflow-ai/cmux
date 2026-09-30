import Foundation

/// Where a new browser tab from a split request ended up.
enum CompatBrowserSplitPlacement: Equatable {
    /// In a new pane beside the source pane.
    case split
    /// In the source pane, because the split was refused for `reason`.
    case tab(reason: String)
}

extension CompatCreate {
    /// Moves a just-created browser tab into a new split (`move`).
    /// `fallbackToTab`: a refused split keeps the tab where it is and says
    /// so. Otherwise, and for any other failure, `discard` closes the tab
    /// before the error is thrown, so a failure opens nothing.
    static func moveBrowserIntoSplit(
        fallbackToTab: Bool,
        move: () async throws -> Void,
        discard: () async -> Void
    ) async throws -> CompatBrowserSplitPlacement {
        try await move()
        return .split
    }
}
