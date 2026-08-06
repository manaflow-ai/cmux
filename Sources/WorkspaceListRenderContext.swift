import CmuxSidebar
import CmuxSettings
import CmuxWorkspaces
import Foundation
import SwiftUI

struct WorkspaceListRenderContext {
    typealias Identity = WorkspaceListRenderContextIdentity
    typealias WorkspaceReferenceIdentity = WorkspaceListWorkspaceReferenceIdentity

    let identity: Identity
    let environment: SidebarWorkspaceTableEnvironmentSnapshot
    let tabs: [Workspace]
    let tabIds: [UUID]
    let sidebarReorderIds: [UUID]
    let workspaceCount: Int
    let canCloseWorkspace: Bool
    let workspaceNumberShortcut: StoredShortcut
    let tabItemSettings: SidebarTabItemSettingsSnapshot
    let showsAgentActivity: Bool
    let pinResolutionContext: WorkspaceActionDispatcher.PinResolutionContext
    let tabIndexById: [UUID: Int]
    let numberedWorkspaceIndexById: [UUID: Int]
    let workspaceById: [UUID: Workspace]
    let workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    let selectedContextTargetIds: [UUID]
    let workspaceGroups: [WorkspaceGroup]
    let workspaceGroupById: [UUID: WorkspaceGroup]
    let memberWorkspaceIdsByGroupId: [UUID: [UUID]]
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let workspaceRenderItems: [SidebarWorkspaceRenderItem]
    let visibleWorkspaceRowIds: [UUID]

    var workspaceIds: [UUID] { tabIds }
}
