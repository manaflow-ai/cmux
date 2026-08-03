import AppKit
import CmuxWorkspaces

// MARK: - Shared status lane list

/// One selectable status lane row, shared by the sidebar row's context-menu
/// Status submenu and the todo pane's status popover so both surfaces present
/// identical lanes, titles, and selection through one model, and apply through
/// the same `WorkspaceTodoActions.applyStatusOverride` path. Sidebar workspace
/// rows may expose this list from the compact manual-status glyph, but automatic
/// status stays out of row chrome.
struct WorkspaceTodoStatusLane: Equatable, Identifiable {
    /// The lane to pin, or `nil` for Auto (clear the override) and for None.
    let status: WorkspaceTaskStatus?
    let title: String
    let isSelected: Bool
    /// The None row: opt the workspace out of the feature (hide the glyph).
    var isNone: Bool = false

    var id: String { isNone ? "none" : (status?.rawValue ?? "auto") }
}

struct SidebarWorkspaceCompactStatusMenuModel: Equatable {
    let inferred: WorkspaceTaskStatus
    let activeOverride: WorkspaceTaskStatus?
}

extension SidebarWorkspaceCompactStatusMenuModel {
    static func resolve(
        inferred: WorkspaceTaskStatus,
        override: WorkspaceTaskStatusOverride?
    ) -> Self {
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: override,
            inferred: inferred
        )
        guard let override, !resolution.shouldClearOverride else {
            return Self(inferred: inferred, activeOverride: nil)
        }
        return Self(inferred: inferred, activeOverride: override.status)
    }
}

extension WorkspaceTodoStatusLane {
    /// The ordered lane list: Auto first, then the five status lanes, then None.
    ///
    /// - Parameters:
    ///   - inferred: The lane the live signals currently infer.
    ///   - activeOverride: The pinned lane, or `nil` while automatic.
    ///   - isHidden: Whether the workspace is opted out (None active).
    static func lanes(
        inferred: WorkspaceTaskStatus,
        activeOverride: WorkspaceTaskStatus?,
        isHidden: Bool = false
    ) -> [WorkspaceTodoStatusLane] {
        var lanes = [WorkspaceTodoStatusLane(
            status: nil,
            title: autoTitle(inferred: inferred, hasOverride: activeOverride != nil),
            isSelected: activeOverride == nil && !isHidden
        )]
        lanes += WorkspaceTaskStatus.allCases.map { status in
            WorkspaceTodoStatusLane(
                status: status,
                title: status.displayName,
                isSelected: !isHidden && activeOverride == status
            )
        }
        lanes.append(WorkspaceTodoStatusLane(
            status: nil,
            title: String(localized: "sidebar.status.none", defaultValue: "None (hide status)"),
            isSelected: isHidden,
            isNone: true
        ))
        return lanes
    }

    /// "Auto — {inferred}" while automatic; "Auto — return to {inferred}"
    /// while a manual lane is pinned.
    static func autoTitle(inferred: WorkspaceTaskStatus, hasOverride: Bool) -> String {
        if hasOverride {
            return String(
                format: String(
                    localized: "sidebar.status.autoReturn",
                    defaultValue: "Auto — return to %@"
                ),
                locale: .current,
                inferred.displayName
            )
        }
        return String(
            format: String(
                localized: "contextMenu.workspaceStatus.auto",
                defaultValue: "Auto — %@"
            ),
            locale: .current,
            inferred.displayName
        )
    }
}

// MARK: - Popover model

/// The value snapshot the status popover renders (Equatable so the NSPopover
/// host only rebuilds content when it actually changes).
struct SidebarWorkspaceStatusPopoverModel: Equatable {
    /// The lane the live signals currently infer.
    let inferred: WorkspaceTaskStatus
    /// The pinned lane, or `nil` while automatic.
    let activeOverride: WorkspaceTaskStatus?
    /// Whether the workspace is opted out (None active).
    var isHidden: Bool = false
}
