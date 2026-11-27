package import Observation

/// Counts the changes of any theme scope's shown picture or its tuning (not its tint). Theme
/// scopes are not observable, so a reader of their backdrop facts (`shownWindowOpacity`) reads
/// this too: Settings' host lists then re-send when a picture comes or goes. Owned by the theme
/// store (`ThemeStore.backdropRevision`), not a process-wide instance of its own.
@MainActor
@Observable
package final class BackdropRevision {
    package init() {}

    package private(set) var value = 0

    package func bump() { value &+= 1 }
}
