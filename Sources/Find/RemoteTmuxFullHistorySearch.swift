import Foundation
import Observation

/// The find bar's "search full tmux history" action for one mirrored pane.
///
/// A mirrored pane's surface holds the attach seed's newest rows plus whatever
/// arrived live, so find stops short of older tmux history. ``load()`` repaints
/// the surface with the whole history and then runs the open search again, so
/// the match count and Return/Shift-Return (and copy mode's `n`/`N`) cover it.
/// The find-bar button, Command-Return in the find field, and find-window's jump
/// all go through this one path.
@MainActor
@Observable
final class RemoteTmuxFullHistorySearch {
    /// Where the load stands.
    enum State: Equatable {
        case notLoaded
        case loading
        case loaded(historyRows: Int, truncated: Bool)
        case alternateScreen
        case failed
    }

    private(set) var state: State = .notLoaded
    @ObservationIgnored private let reseed: @MainActor () async -> RemoteTmuxFullHistorySeedOutcome
    @ObservationIgnored private let rerunSearch: @MainActor () -> Void

    /// - Parameters:
    ///   - reseed: repaints the pane with its full history.
    ///   - rerunSearch: runs the surface's open search again over the new rows.
    init(
        reseed: @escaping @MainActor () async -> RemoteTmuxFullHistorySeedOutcome,
        rerunSearch: @escaping @MainActor () -> Void
    ) {
        self.reseed = reseed
        self.rerunSearch = rerunSearch
    }

    /// Loads the full history unless a load is already running. Returns whether
    /// this call loaded it.
    @discardableResult
    func load() async -> Bool {
        guard state != .loading else { return false }
        state = .loading
        let outcome = await reseed()
        switch outcome {
        case let .loaded(historyRows, truncated):
            state = .loaded(historyRows: historyRows, truncated: truncated)
            rerunSearch()
            return true
        case .alternateScreen:
            state = .alternateScreen
            return false
        case .failed:
            state = .failed
            return false
        }
    }
}
