public import CmuxNextLayout
public import CmuxNextSidebar
public import CmuxNextTabs

// The layout, strip and sidebar halves of the id aliases (the daemon ones are
// CmuxNextBridge's BridgeAliases.swift): app code imports every module that
// names a `PaneID` or `TabID`, so it uses these unambiguous names.

public typealias LayoutPaneID = CmuxNextLayout.PaneID
public typealias LayoutSplitID = CmuxNextLayout.SplitID
public typealias LayoutColumnID = CmuxNextLayout.ColumnID
public typealias LayoutRowID = CmuxNextLayout.RowID
public typealias LayoutScreenID = CmuxNextLayout.ScreenID
public typealias LayoutTabID = CmuxNextLayout.TabID
public typealias LayoutDropTarget = CmuxNextLayout.DropTarget

public typealias StripTabID = CmuxNextTabs.TabID
public typealias StripTabItem = CmuxNextTabs.TabItem

public typealias SidebarRowSection = CmuxNextSidebar.SidebarSection
public typealias SidebarWorkspaceID = CmuxNextSidebar.WorkspaceID
public typealias SidebarProfileKey = CmuxNextSidebar.ProfileKey
