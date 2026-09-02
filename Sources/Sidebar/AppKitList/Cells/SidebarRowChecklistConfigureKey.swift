import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Immutable render inputs used to bypass unrelated pooled checklist updates.
struct SidebarRowChecklistConfigureKey: Equatable {
    let workspaceId: UUID
    let items: [WorkspaceChecklistItem]
    let title: String
    let completedCount: Int
    let totalCount: Int
    let firstUncheckedText: String?
    let isActive: Bool
    let isMultiSelected: Bool
    let colorSchemeIsDark: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let magnificationPercent: Int
    let isExpanded: Bool
    let token: Int
    let popoverPresented: Bool
    let editingItemId: UUID?
    let todoControlsEnabled: Bool
    /// Prevents a palette-only change from taking the unchanged-render fast path.
    let chromePalette: ChromePalette
}
