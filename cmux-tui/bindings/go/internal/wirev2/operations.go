// Package wirev2 centralizes the resource API's wire vocabulary.
//
// It is internal so the public facade can evolve without exposing protocol
// spelling as API. The raw protocol package remains available separately at
// github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw.
package wirev2

const Protocol = "cmux.protocol/2"

type Class uint8

const (
	Read Class = iota
	Mutation
	StreamOpen
	ConnectionControl
)

type Operation struct {
	Name  string
	Class Class
}

func (class Class) String() string {
	switch class {
	case Read:
		return "read"
	case Mutation:
		return "mutation"
	case StreamOpen:
		return "stream_open"
	case ConnectionControl:
		return "connection_control"
	default:
		return "unknown"
	}
}

var (
	MachineList = Operation{"machine.list", Read}
	MachineGet  = Operation{"machine.get", Read}

	SessionList                   = Operation{"session.list", Read}
	SessionOpen                   = Operation{"session.open", Mutation}
	SessionGet                    = Operation{"session.get", Read}
	SessionSnapshot               = Operation{"session.snapshot", Read}
	SessionCreationResolve        = Operation{"session.creation.resolve", Read}
	SessionEvents                 = Operation{"session.events", StreamOpen}
	SessionJournalSubscribe       = Operation{"session.journal.subscribe", StreamOpen}
	SessionPing                   = Operation{"session.ping", Read}
	SessionShutdown               = Operation{"session.shutdown", Mutation}
	SessionReloadConfig           = Operation{"session.reload_config", Mutation}
	SessionTerminalDefaultsUpdate = Operation{"session.terminal_defaults.update", Mutation}
	SessionWindowTitleSet         = Operation{"session.window.title.set", Mutation}
	SessionWindowTitleClear       = Operation{"session.window.title.clear", Mutation}

	ClientList           = Operation{"client.list", Read}
	ClientGet            = Operation{"client.get", Read}
	ClientMetadataUpdate = Operation{"client.metadata.update", ConnectionControl}
	ClientSizingSet      = Operation{"client.sizing.set", ConnectionControl}
	ClientSizingRelease  = Operation{"client.sizing.release", ConnectionControl}
	ClientCellPixelsSet  = Operation{"client.cell_pixels.set", ConnectionControl}
	ClientDetach         = Operation{"client.detach", ConnectionControl}

	PairingRequestList    = Operation{"pairing_request.list", Read}
	PairingRequestResolve = Operation{"pairing_request.resolve", Mutation}
	ProjectionGet         = Operation{"frontend_projection.get", Read}
	ProjectionPut         = Operation{"frontend_projection.put", Mutation}

	WorkspaceList        = Operation{"workspace.list", Read}
	WorkspaceGet         = Operation{"workspace.get", Read}
	WorkspaceCreate      = Operation{"workspace.create", Mutation}
	WorkspaceRename      = Operation{"workspace.rename", Mutation}
	WorkspaceMove        = Operation{"workspace.move", Mutation}
	WorkspaceFocus       = Operation{"workspace.focus", Mutation}
	WorkspaceClose       = Operation{"workspace.close", Mutation}
	WorkspaceRun         = Operation{"workspace.run", Mutation}
	WorkspaceLayoutApply = Operation{"workspace.layout.apply", Mutation}

	ScreenList         = Operation{"screen.list", Read}
	ScreenGet          = Operation{"screen.get", Read}
	ScreenCreate       = Operation{"screen.create", Mutation}
	ScreenRename       = Operation{"screen.rename", Mutation}
	ScreenFocus        = Operation{"screen.focus", Mutation}
	ScreenClose        = Operation{"screen.close", Mutation}
	ScreenLayoutExport = Operation{"screen.layout.export", Read}
	ScreenLayoutUndo   = Operation{"screen.layout.undo", Mutation}

	PaneList             = Operation{"pane.list", Read}
	PaneGet              = Operation{"pane.get", Read}
	PaneCreate           = Operation{"pane.create", Mutation}
	PaneSplit            = Operation{"pane.split", Mutation}
	PaneRename           = Operation{"pane.rename", Mutation}
	PaneFocus            = Operation{"pane.focus", Mutation}
	PaneFocusDirection   = Operation{"pane.focus_direction", Mutation}
	PaneNeighborGet      = Operation{"pane.neighbor.get", Read}
	PaneSwap             = Operation{"pane.swap", Mutation}
	PaneZoom             = Operation{"pane.zoom", Mutation}
	PaneSplitRatioSet    = Operation{"pane.split_ratio.set", Mutation}
	PaneViewportWidthSet = Operation{"pane.viewport_width.set", Mutation}
	PaneClose            = Operation{"pane.close", Mutation}
	PaneRun              = Operation{"pane.run", Mutation}

	TabList           = Operation{"tab.list", Read}
	TabGet            = Operation{"tab.get", Read}
	TabCreateTerminal = Operation{"tab.create_terminal", Mutation}
	TabCreateBrowser  = Operation{"tab.create_browser", Mutation}
	TabRename         = Operation{"tab.rename", Mutation}
	TabMove           = Operation{"tab.move", Mutation}
	TabFocus          = Operation{"tab.focus", Mutation}
	TabClose          = Operation{"tab.close", Mutation}

	TerminalList                = Operation{"terminal.list", Read}
	TerminalGet                 = Operation{"terminal.get", Read}
	TerminalInputWrite          = Operation{"terminal.input.write", Mutation}
	TerminalInputKeys           = Operation{"terminal.input.keys", Mutation}
	TerminalInputMouse          = Operation{"terminal.input.mouse", Mutation}
	TerminalInputFocus          = Operation{"terminal.input.focus", Mutation}
	TerminalScreenRead          = Operation{"terminal.screen.read", Read}
	TerminalStateRead           = Operation{"terminal.state.read", Read}
	TerminalHistoryRead         = Operation{"terminal.history.read", Read}
	TerminalHistoryClear        = Operation{"terminal.history.clear", Mutation}
	TerminalWait                = Operation{"terminal.wait", Read}
	TerminalWaitExit            = Operation{"terminal.wait_exit", Read}
	TerminalCopy                = Operation{"terminal.copy", Read}
	TerminalProcessGet          = Operation{"terminal.process.get", Read}
	TerminalViewerResize        = Operation{"terminal.viewer.resize", ConnectionControl}
	TerminalViewerRelease       = Operation{"terminal.viewer.release", ConnectionControl}
	TerminalRendererGrantCreate = Operation{"terminal.renderer_grant.create", ConnectionControl}
	TerminalViewportScroll      = Operation{"terminal.viewport.scroll", Mutation}
	TerminalMove                = Operation{"terminal.move", Mutation}
	TerminalProject             = Operation{"terminal.project", Mutation}
	TerminalAttach              = Operation{"terminal.attach", StreamOpen}
	TerminalClose               = Operation{"terminal.close", Mutation}

	BrowserList          = Operation{"browser.list", Read}
	BrowserGet           = Operation{"browser.get", Read}
	BrowserNavigate      = Operation{"browser.navigate", Mutation}
	BrowserBack          = Operation{"browser.back", Mutation}
	BrowserForward       = Operation{"browser.forward", Mutation}
	BrowserReload        = Operation{"browser.reload", Mutation}
	BrowserActivate      = Operation{"browser.activate", Mutation}
	BrowserInputKey      = Operation{"browser.input.key", Mutation}
	BrowserInputText     = Operation{"browser.input.text", Mutation}
	BrowserInputMouse    = Operation{"browser.input.mouse", Mutation}
	BrowserInputWheel    = Operation{"browser.input.wheel", Mutation}
	BrowserViewerResize  = Operation{"browser.viewer.resize", ConnectionControl}
	BrowserViewerRelease = Operation{"browser.viewer.release", ConnectionControl}
	BrowserAttach        = Operation{"browser.attach", StreamOpen}
	BrowserClose         = Operation{"browser.close", Mutation}

	NotificationList   = Operation{"notification.list", Read}
	NotificationCreate = Operation{"notification.create", Mutation}
	AgentList          = Operation{"agent.list", Read}
	AgentReport        = Operation{"agent.report", Mutation}

	SidebarViewGet    = Operation{"sidebar_view.get", Read}
	SidebarViewEnsure = Operation{"sidebar_view.ensure", Mutation}
	SidebarViewAttach = Operation{"sidebar_view.attach", StreamOpen}
	SidebarViewInput  = Operation{"sidebar_view.input", Mutation}
	SidebarViewResize = Operation{"sidebar_view.resize", Mutation}
	SidebarViewReload = Operation{"sidebar_view.reload", Mutation}

	RequestCancel = Operation{"request.cancel", ConnectionControl}
	StreamCancel  = Operation{"stream.cancel", ConnectionControl}
)

const (
	FieldSelector        = "selector"
	FieldMachine         = "machine"
	FieldSession         = "session"
	FieldWorkspace       = "workspace"
	FieldScreen          = "screen"
	FieldPane            = "pane"
	FieldTab             = "tab"
	FieldTerminal        = "terminal"
	FieldBrowser         = "browser"
	FieldClient          = "client"
	FieldStreamID        = "stream_id"
	FieldRequestID       = "request_id"
	FieldIdempotencyKey  = "idempotency_key"
	FieldArgv            = "argv"
	FieldName            = "name"
	FieldKind            = "kind"
	FieldForce           = "force"
	FieldConnection      = "connection"
	FieldInitialContent  = "initial_content"
	FieldCWD             = "cwd"
	FieldEnv             = "env"
	FieldLayout          = "layout"
	FieldDirection       = "direction"
	FieldRatio           = "ratio"
	FieldViewportWidth   = "viewport_width"
	FieldWidth           = "width"
	FieldCols            = "cols"
	FieldRows            = "rows"
	FieldEnabled         = "enabled"
	FieldData            = "data"
	FieldKeys            = "keys"
	FieldMouse           = "mouse"
	FieldFocused         = "focused"
	FieldStart           = "start"
	FieldCount           = "count"
	FieldMode            = "mode"
	FieldText            = "text"
	FieldURL             = "url"
	FieldDelta           = "delta"
	FieldGeneration      = "generation"
	FieldRevision        = "revision"
	FieldCursor          = "cursor"
	FieldPointerFrameSeq = "pointer_frame_seq"
	FieldTimeoutMS       = "timeout_ms"
	FieldTitle           = "title"
	FieldBody            = "body"
	FieldLevel           = "level"
	FieldState           = "state"
	FieldDetails         = "details"
	FieldAccept          = "accept"
	FieldValue           = "value"
	FieldInput           = "input"
	FieldPlugin          = "plugin"
	FieldAction          = "action"
	FieldScope           = "scope"
	FieldMetadata        = "metadata"
)
