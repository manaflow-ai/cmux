import CmuxMobileShellModel

struct WorkspaceGroupHeaderRowActions {
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let renameGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)?
    let setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    let ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)?
    let toggleCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
}
