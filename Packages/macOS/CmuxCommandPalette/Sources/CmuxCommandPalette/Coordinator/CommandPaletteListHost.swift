/// Read-and-act seam the host fills so ``CommandPaletteCoordinator`` can drive
/// the command palette's keyboard/selection navigation and list-reaction
/// handlers without importing AppKit, SwiftUI, or any app-target window type.
///
/// The coordinator owns the navigation/scroll/selection-anchor bookkeeping and
/// the four list-reaction transitions (query change, search-fingerprint change,
/// results-revision change, selected-index change). Everything that needs an
/// app-target effect, the system beep, the SwiftUI `withAnimation` wrapper, the
/// per-window debug-state sync, and the results-refresh pipeline, stays on the
/// conformer side (`ContentView`) and is reached through this protocol.
///
/// Mirroring the package's other palette seams, the host is a value-typed
/// SwiftUI `View` that is reconstructed every render, so the coordinator never
/// stores it: each driving method takes the current host.
///
/// ## Isolation
///
/// Every requirement is `@MainActor`: selection navigation, list reactions, the
/// beep, the animation wrapper, the debug-state sync, and the results refresh
/// all run on the main actor (SwiftUI view updates, keyboard handling, and
/// socket commands that hop to main).
///
/// The protocol refines `Sendable` so the results-refresh pipeline can capture
/// the host in its detached search task and call back through it on the main
/// actor; every conformer is a `@MainActor`-isolated app type, which satisfies
/// `Sendable` for free.
@MainActor
public protocol CommandPaletteListHost: Sendable {
    /// Emits the system beep used when a selection move has no results to move
    /// through.
    func commandPaletteListBeep()

    /// Runs `body` inside the host's selection-scroll animation, so the scroll
    /// target assignment animates exactly as the legacy `withAnimation` site did.
    func commandPaletteListAnimate(_ body: () -> Void)

    /// Synchronizes the per-window palette debug state for the observed window.
    func commandPaletteListSyncDebugState()

    /// Schedules a results refresh against the current corpus/index. `query` is
    /// `nil` to refresh the live query; `force` forces a search-corpus rebuild;
    /// `preservePendingActivation` rebases the queued activation onto the new
    /// request instead of clearing it.
    func commandPaletteListScheduleResultsRefresh(
        query: String?,
        force: Bool,
        preservePendingActivation: Bool
    )

    /// Runs a resolved palette activation (executing the activated command or
    /// the selected result). Called by the results-refresh pipeline once a
    /// pending activation resolves against freshly materialized results.
    func commandPaletteListRunResolvedActivation(_ activation: CommandPaletteResolvedActivation)
}
