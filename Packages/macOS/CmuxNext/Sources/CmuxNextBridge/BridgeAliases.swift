public import CmuxNextDaemon
public import CmuxNextLayout
public import CmuxNextSidebar
public import CmuxNextTabs

// The daemon, layout, sidebar, and tab modules each name their own ids
// (`PaneID`, `SplitID`, `TabID`, ...). App code imports all of them, so it
// uses these unambiguous aliases instead of module-qualified names.

public typealias DaemonPaneID = CmuxNextDaemon.PaneID
public typealias DaemonSplitID = CmuxNextDaemon.SplitID
public typealias DaemonColumnID = CmuxNextDaemon.ColumnID
public typealias DaemonRowID = CmuxNextDaemon.RowID
public typealias DaemonScreenID = CmuxNextDaemon.ScreenID
public typealias DaemonSidebarSection = CmuxNextDaemon.SidebarSection

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
public typealias SidebarDropTarget = CmuxNextSidebar.DropTarget
