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
        do {
            try await move()
            return .split
        } catch {
            if fallbackToTab, let reason = refusalReason(error) { return .tab(reason: reason) }
            await discard()
            throw error
        }
    }

    /// The reason of a refused `tab.moveToNewSplit` (`runAction` reports a
    /// refusal as `unavailable` with the handler's reason). A refused move
    /// did not run, so the tab is still in the source pane.
    static func refusalReason(_ error: any Error) -> String? {
        guard let error = error as? ControlError, error.code == "unavailable",
              error.data?["action"]?.stringValue == "tab.moveToNewSplit" else { return nil }
        return error.data?["reason"]?.stringValue
    }
}
