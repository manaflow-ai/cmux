/// `tabs.swapCmdTAndCmdN` in cmux.json (cx-xt5k): off by default, so Cmd-T
/// opens a tab in a pane with a tab strip and a workspace from an agent chat
/// or a pane without one, and Cmd-N opens a workspace. On, Cmd-T always opens
/// a workspace in the current group and Cmd-N a tab; both open the New Tab
/// page. A binding the user set for either action wins.
public nonisolated enum SwapCmdTAndCmdNSetting {
}
