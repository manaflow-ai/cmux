import Observation

/// Counts the changes of any theme scope's shown picture or its tuning (not its tint). Theme
/// scopes are not observable, so a reader of their backdrop facts (`shownWindowOpacity`) reads
/// this too: Settings' host lists then re-send when a picture comes or goes.
@MainActor
@Observable
final class BackdropRevision {
    static let shared = BackdropRevision()

    private(set) var value = 0

    func bump() { value &+= 1 }
}
