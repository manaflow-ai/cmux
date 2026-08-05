import CmuxSettings
import CmuxWorkspaces
import Foundation
import SwiftUI

struct WorkspaceListRenderContextIdentity: Equatable {
    let workspaceReferences: [WorkspaceListWorkspaceReferenceIdentity]
    let selectedWorkspaceId: UUID?
    let selectedContextTargetIds: [UUID]
    let sidebarReorderIds: [UUID]
    let workspaceGroups: [WorkspaceGroup]
    let workspaceRenderItemIds: [SidebarWorkspaceRenderItemID]
    let workspaceNumberShortcut: StoredShortcut
    let tabItemSettings: SidebarTabItemSettingsSnapshot
    let showsAgentActivity: Bool
    let sidebarSelectionIsTabs: Bool
    let colorScheme: ColorScheme
    let globalFontMagnificationPercent: Int
}
