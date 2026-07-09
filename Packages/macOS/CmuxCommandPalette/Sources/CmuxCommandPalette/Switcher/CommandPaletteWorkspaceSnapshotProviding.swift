internal import Foundation

/// Read-only seam the host fills from its live window/tab/workspace state so the
/// package's ``CommandPaletteSwitcherEntryBuilder`` can build the switcher
/// entries and fingerprint without importing app-target god types.
///
/// The conformer (an app-target adapter over `TabManager` and the app delegate)
/// resolves the ordered window contexts, ordered workspaces, ordered surfaces,
/// display names, localized labels, searchable metadata, and per-row activation
/// actions, returning them as the package's plain snapshot value types. All live
/// state reads and `String(localized:)` resolution stay on the conformer side.
@MainActor
public protocol CommandPaletteWorkspaceSnapshotProviding {
    /// Builds the ordered switcher window contexts for the current state.
    ///
    /// - Parameter includeSurfaces: when `true`, each workspace carries its
    ///   ordered surfaces; when `false`, workspaces carry no surfaces.
    func makeSwitcherSnapshot(
        includeSurfaces: Bool
    ) -> [CommandPaletteSwitcherSnapshotWindow]
}
