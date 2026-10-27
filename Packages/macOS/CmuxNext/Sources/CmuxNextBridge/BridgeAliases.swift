public import CmuxNextDaemon

// The daemon, layout, sidebar, and tab modules each name their own ids
// (`PaneID`, `SplitID`, `TabID`, ...). App code imports all of them, so it
// uses these unambiguous aliases instead of module-qualified names. The
// layout, strip and sidebar ones are CmuxNextBridgeUI's (BridgeUIAliases.swift).

public typealias DaemonPaneID = CmuxNextDaemon.PaneID
public typealias DaemonSplitID = CmuxNextDaemon.SplitID
public typealias DaemonColumnID = CmuxNextDaemon.ColumnID
public typealias DaemonRowID = CmuxNextDaemon.RowID
public typealias DaemonScreenID = CmuxNextDaemon.ScreenID
public typealias DaemonSidebarSection = CmuxNextDaemon.SidebarSection
