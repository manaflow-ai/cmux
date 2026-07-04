import CmuxWorkspaces
import Foundation

/// Immutable per-row snapshot for a top-level workstream row in the sidebar.
///
/// Built once per sidebar render in the view body (the single place that may
/// read stores) and handed to `SidebarWorkstreamRowView` below the list
/// boundary as a value, honoring the snapshot-boundary rule in CLAUDE.md.
struct SidebarWorkstreamRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Resolved SF Symbol name (already defaulted; never empty).
    let iconSymbol: String
    /// Optional tint hex (e.g. "#C0392B"); nil uses the default secondary tint.
    let tintHex: String?
    /// Number of PR-workspaces assigned to this workstream.
    let workspaceCount: Int
    /// Aggregate unread count across the workstream's workspaces — the
    /// portfolio "rollup" surfaced at the top level (mirrors how a collapsed
    /// `WorkspaceGroup` header sums its members' unread counts).
    let unreadCount: Int
    /// Whether the currently-selected workspace lives inside this workstream.
    let containsSelectedWorkspace: Bool
}

/// Pure builders for the workstream sidebar rows. Kept free of SwiftUI/store
/// references so the rollup math is unit-testable.
enum SidebarWorkstreamRenderModel {
    /// Default SF Symbol for a workstream row when it has no custom icon.
    static let defaultIconSymbol = "rectangle.stack"

    /// Build one row snapshot per workstream (in master-list order), computing
    /// the per-workstream rollup in a single pass over `tabs`.
    ///
    /// - Parameters:
    ///   - workstreams: the master list (already in display order).
    ///   - tabs: every workspace in the window (membership read via `workstreamId`).
    ///   - selectedWorkspaceId: the focused workspace, for the active marker.
    ///   - unreadCount: per-workspace unread lookup (injected so this stays pure).
    ///
    /// `@MainActor` because `WorkspaceTabRepresenting` (hence `tab.workstreamId`)
    /// is main-actor isolated; every caller (the sidebar body, tests) is too.
    @MainActor
    static func rowSnapshots<Tab: WorkspaceTabRepresenting>(
        workstreams: [Workstream],
        tabs: [Tab],
        selectedWorkspaceId: UUID?,
        unreadCount: (UUID) -> Int
    ) -> [SidebarWorkstreamRowSnapshot] {
        guard !workstreams.isEmpty else { return [] }
        var countById: [UUID: Int] = [:]
        var unreadById: [UUID: Int] = [:]
        var selectedWorkstreamId: UUID?
        for tab in tabs {
            guard let wsId = tab.workstreamId else { continue }
            countById[wsId, default: 0] += 1
            unreadById[wsId, default: 0] += unreadCount(tab.id)
            if tab.id == selectedWorkspaceId { selectedWorkstreamId = wsId }
        }
        return workstreams.map { workstream in
            SidebarWorkstreamRowSnapshot(
                id: workstream.id,
                name: workstream.name,
                iconSymbol: workstream.iconSymbol ?? defaultIconSymbol,
                tintHex: workstream.customColor,
                workspaceCount: countById[workstream.id] ?? 0,
                unreadCount: unreadById[workstream.id] ?? 0,
                containsSelectedWorkspace: selectedWorkstreamId == workstream.id
            )
        }
    }
}
