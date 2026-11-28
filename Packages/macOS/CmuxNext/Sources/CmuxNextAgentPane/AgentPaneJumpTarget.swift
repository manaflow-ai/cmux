/// What the location bar can jump to (`tab.jump`). `here` moves an open tab into the
/// pane showing the page (its Open Tabs list, cx-jfo7); `closed` reopens a recently
/// closed tab, screen or workspace by its history id (Recently Closed, cx-d0d.60).
public nonisolated enum AgentPaneJumpTarget: String, Sendable {
    case tab, workspace, here, closed
}
