import Bonsplit
import Foundation

/// Value snapshot of the selected workspace's overlay dependencies.
///
/// Read in a SwiftUI leaf so every model dependency is tracked there. Equality
/// excludes unrelated workspace notifications, tab titles and snapshot time.
struct TmuxWorkspacePaneOverlayInputs: Hashable {
    var target: TmuxOverlayExperimentTarget
    var settings: TmuxWorkspacePaneOverlaySettings
    var workspaceId: UUID?
    var workspaceIdentity: ObjectIdentifier?
    var layout: LayoutSnapshot?
    var isCanvas = false
    var isZoomed = false
    var panelIdentities: [UUID: ObjectIdentifier] = [:]
    var focusedPanelId: UUID?
    var selectionRevision: UInt64 = 0
    var unreadPanelIds: Set<UUID> = []
    var notificationPanelIds: Set<UUID> = []
    var isWorkspaceManuallyUnread = false
    var manualUnreadRepresentative: UUID?
    var flashPanelId: UUID?
    var flashToken: UInt64 = 0
    var flashReason: WorkspaceAttentionFlashReason?

    /// Whether the controller may have visible content for these inputs.
    var isVisible: Bool {
        workspaceId != nil && (target.usesWorkspacePaneOverlay || (
            settings.activePaneBorderColorHex != nil && !isCanvas
                && !settings.rightSidebarOwnsInputFocus && (layout?.panes.count ?? 0) > 1
        ))
    }

    /// WindowAccessor compares full value equality; hashing a stable identity
    /// avoids walking the pane arrays merely to erase the refresh key.
    func hash(into hasher: inout Hasher) {
        hasher.combine(workspaceIdentity)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
            && lhs.settings == rhs.settings
            && lhs.workspaceId == rhs.workspaceId
            && lhs.workspaceIdentity == rhs.workspaceIdentity
            && lhs.layout == rhs.layout
            && lhs.isCanvas == rhs.isCanvas
            && lhs.isZoomed == rhs.isZoomed
            && lhs.panelIdentities == rhs.panelIdentities
            && lhs.focusedPanelId == rhs.focusedPanelId
            && lhs.selectionRevision == rhs.selectionRevision
            && lhs.unreadPanelIds == rhs.unreadPanelIds
            && lhs.notificationPanelIds == rhs.notificationPanelIds
            && lhs.isWorkspaceManuallyUnread == rhs.isWorkspaceManuallyUnread
            && lhs.manualUnreadRepresentative == rhs.manualUnreadRepresentative
            && lhs.flashPanelId == rhs.flashPanelId
            && lhs.flashToken == rhs.flashToken
            && lhs.flashReason == rhs.flashReason
    }
}
