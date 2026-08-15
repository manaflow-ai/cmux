export type OperationClass =
  | "read"
  | "mutation"
  | "stream_open"
  | "connection_control"
  | "local";

export interface Operation {
  readonly name: string;
  readonly class: OperationClass;
}

const op = (name: string, operationClass: OperationClass): Operation =>
  Object.freeze({ name, class: operationClass });

export const operations = Object.freeze({
  machineList: op("machine.list", "read"),
  machineGet: op("machine.get", "read"),

  sessionList: op("session.list", "read"),
  sessionOpen: op("session.open", "mutation"),
  sessionGet: op("session.get", "read"),
  sessionSnapshot: op("session.snapshot", "read"),
  sessionCreationResolve: op("session.creation.resolve", "read"),
  sessionEvents: op("session.events", "stream_open"),
  sessionJournalSubscribe: op("session.journal.subscribe", "stream_open"),
  sessionPing: op("session.ping", "read"),
  sessionShutdown: op("session.shutdown", "mutation"),
  sessionReloadConfig: op("session.reload_config", "mutation"),
  sessionTerminalDefaultsUpdate: op("session.terminal_defaults.update", "mutation"),
  sessionWindowTitleSet: op("session.window.title.set", "mutation"),
  sessionWindowTitleClear: op("session.window.title.clear", "mutation"),

  clientList: op("client.list", "read"),
  clientGet: op("client.get", "read"),
  clientMetadataUpdate: op("client.metadata.update", "connection_control"),
  clientSizingSet: op("client.sizing.set", "connection_control"),
  clientSizingRelease: op("client.sizing.release", "connection_control"),
  clientCellPixelsSet: op("client.cell_pixels.set", "connection_control"),
  clientDetach: op("client.detach", "connection_control"),

  pairingRequestList: op("pairing_request.list", "read"),
  pairingRequestResolve: op("pairing_request.resolve", "mutation"),
  frontendProjectionGet: op("frontend_projection.get", "read"),
  frontendProjectionPut: op("frontend_projection.put", "mutation"),

  workspaceList: op("workspace.list", "read"),
  workspaceGet: op("workspace.get", "read"),
  workspaceCreate: op("workspace.create", "mutation"),
  workspaceRename: op("workspace.rename", "mutation"),
  workspaceMove: op("workspace.move", "mutation"),
  workspaceFocus: op("workspace.focus", "mutation"),
  workspaceClose: op("workspace.close", "mutation"),
  workspaceRun: op("workspace.run", "mutation"),
  workspaceLayoutApply: op("workspace.layout.apply", "mutation"),

  screenList: op("screen.list", "read"),
  screenGet: op("screen.get", "read"),
  screenCreate: op("screen.create", "mutation"),
  screenRename: op("screen.rename", "mutation"),
  screenFocus: op("screen.focus", "mutation"),
  screenClose: op("screen.close", "mutation"),
  screenLayoutExport: op("screen.layout.export", "read"),
  screenLayoutUndo: op("screen.layout.undo", "mutation"),

  paneList: op("pane.list", "read"),
  paneGet: op("pane.get", "read"),
  paneCreate: op("pane.create", "mutation"),
  paneSplit: op("pane.split", "mutation"),
  paneRename: op("pane.rename", "mutation"),
  paneFocus: op("pane.focus", "mutation"),
  paneFocusDirection: op("pane.focus_direction", "mutation"),
  paneNeighborGet: op("pane.neighbor.get", "read"),
  paneSwap: op("pane.swap", "mutation"),
  paneZoom: op("pane.zoom", "mutation"),
  paneSplitRatioSet: op("pane.split_ratio.set", "mutation"),
  paneViewportWidthSet: op("pane.viewport_width.set", "mutation"),
  paneClose: op("pane.close", "mutation"),
  paneRun: op("pane.run", "mutation"),

  tabList: op("tab.list", "read"),
  tabGet: op("tab.get", "read"),
  tabCreateTerminal: op("tab.create_terminal", "mutation"),
  tabCreateBrowser: op("tab.create_browser", "mutation"),
  tabRename: op("tab.rename", "mutation"),
  tabMove: op("tab.move", "mutation"),
  tabFocus: op("tab.focus", "mutation"),
  tabClose: op("tab.close", "mutation"),

  terminalList: op("terminal.list", "read"),
  terminalGet: op("terminal.get", "read"),
  terminalInputWrite: op("terminal.input.write", "mutation"),
  terminalInputKeys: op("terminal.input.keys", "mutation"),
  terminalInputMouse: op("terminal.input.mouse", "mutation"),
  terminalInputFocus: op("terminal.input.focus", "mutation"),
  terminalScreenRead: op("terminal.screen.read", "read"),
  terminalStateRead: op("terminal.state.read", "read"),
  terminalHistoryRead: op("terminal.history.read", "read"),
  terminalHistoryClear: op("terminal.history.clear", "mutation"),
  terminalWait: op("terminal.wait", "read"),
  terminalWaitExit: op("terminal.wait_exit", "read"),
  terminalCopy: op("terminal.copy", "read"),
  terminalProcessGet: op("terminal.process.get", "read"),
  terminalRendererGrantCreate: op(
    "terminal.renderer_grant.create",
    "connection_control",
  ),
  terminalViewerResize: op("terminal.viewer.resize", "connection_control"),
  terminalViewerRelease: op("terminal.viewer.release", "connection_control"),
  terminalViewportScroll: op("terminal.viewport.scroll", "mutation"),
  terminalMove: op("terminal.move", "mutation"),
  terminalProject: op("terminal.project", "mutation"),
  terminalAttach: op("terminal.attach", "stream_open"),
  terminalClose: op("terminal.close", "mutation"),

  browserList: op("browser.list", "read"),
  browserGet: op("browser.get", "read"),
  browserNavigate: op("browser.navigate", "mutation"),
  browserBack: op("browser.back", "mutation"),
  browserForward: op("browser.forward", "mutation"),
  browserReload: op("browser.reload", "mutation"),
  browserActivate: op("browser.activate", "mutation"),
  browserInputKey: op("browser.input.key", "mutation"),
  browserInputText: op("browser.input.text", "mutation"),
  browserInputMouse: op("browser.input.mouse", "mutation"),
  browserInputWheel: op("browser.input.wheel", "mutation"),
  browserViewerResize: op("browser.viewer.resize", "connection_control"),
  browserViewerRelease: op("browser.viewer.release", "connection_control"),
  browserAttach: op("browser.attach", "stream_open"),
  browserClose: op("browser.close", "mutation"),

  notificationList: op("notification.list", "read"),
  notificationCreate: op("notification.create", "mutation"),
  agentList: op("agent.list", "read"),
  agentReport: op("agent.report", "mutation"),

  sidebarViewGet: op("sidebar_view.get", "read"),
  sidebarViewEnsure: op("sidebar_view.ensure", "mutation"),
  sidebarViewAttach: op("sidebar_view.attach", "stream_open"),
  sidebarViewInput: op("sidebar_view.input", "mutation"),
  sidebarViewResize: op("sidebar_view.resize", "mutation"),
  sidebarViewReload: op("sidebar_view.reload", "mutation"),

  requestCancel: op("request.cancel", "connection_control"),
  streamCancel: op("stream.cancel", "connection_control"),

  sidebarPluginList: op("sidebar_plugin.list", "local"),
  sidebarPluginInstall: op("sidebar_plugin.install", "local"),
  sidebarPluginUse: op("sidebar_plugin.use", "local"),
  sidebarPluginUpdate: op("sidebar_plugin.update", "local"),
  sidebarPluginRemove: op("sidebar_plugin.remove", "local"),
  sidebarPluginUseBuiltin: op("sidebar_plugin.use_builtin", "local"),
});

export const transportedOperations = Object.freeze(
  Object.values(operations).filter((operation) => operation.class !== "local"),
);
