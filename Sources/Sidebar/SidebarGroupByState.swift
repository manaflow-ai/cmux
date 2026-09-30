import Foundation
import Observation

/// Per-window Group By choice for the workspace sidebar.
///
/// Owned by the window's `TabManager`. The sidebar body reads it through
/// Observation, so a mode change or a section collapse redraws that window only.
@MainActor
@Observable
final class SidebarGroupByState {
    /// The active arrangement. Persisted in the window's session snapshot.
    var mode: SidebarGroupByMode = .manual
    /// Collapsed automatic sections, keyed by `SidebarAutoGroupingSection.key`.
    /// Session-only: sections are derived, so a relaunch starts expanded.
    var collapsedSectionKeys: Set<String> = []

    func toggleCollapsed(sectionKey: String) {
        if collapsedSectionKeys.contains(sectionKey) {
            collapsedSectionKeys.remove(sectionKey)
        } else {
            collapsedSectionKeys.insert(sectionKey)
        }
    }
}
