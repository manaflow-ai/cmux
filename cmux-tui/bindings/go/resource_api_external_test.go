package cmux_test

import (
	"context"
	"testing"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

func TestResourceCollectionsExposePointerHandles(t *testing.T) {
	var _ func(*cmux.Client, cmux.Selector[cmux.SessionID]) *cmux.Session = (*cmux.Client).Session
	var _ func(*cmux.Client, context.Context, cmux.MachineListOptions) ([]*cmux.Machine, error) = (*cmux.Client).ListMachines
	var _ func(*cmux.Client, context.Context, string) ([]*cmux.Machine, error) = (*cmux.Client).FindMachinesByName
	var _ func(*cmux.Machine, context.Context, cmux.SessionListOptions) ([]*cmux.Session, error) = (*cmux.Machine).ListSessions
	var _ func(*cmux.Machine, context.Context, string) ([]*cmux.Session, error) = (*cmux.Machine).FindSessionsByName
	var _ func(*cmux.Session, context.Context, cmux.WorkspaceListOptions) ([]*cmux.Workspace, error) = (*cmux.Session).ListWorkspaces
	var _ func(*cmux.Session, context.Context, string) ([]*cmux.Workspace, error) = (*cmux.Session).FindWorkspacesByName
	var _ func(*cmux.Workspace, context.Context, cmux.ScreenListOptions) ([]*cmux.Screen, error) = (*cmux.Workspace).ListScreens
	var _ func(*cmux.Workspace, context.Context, string) ([]*cmux.Screen, error) = (*cmux.Workspace).FindScreensByName
	var _ func(*cmux.Screen, context.Context, cmux.PaneListOptions) ([]*cmux.Pane, error) = (*cmux.Screen).ListPanes
	var _ func(*cmux.Screen, context.Context, string) ([]*cmux.Pane, error) = (*cmux.Screen).FindPanesByName
	var _ func(*cmux.Pane, context.Context, cmux.TabListOptions) ([]*cmux.Tab, error) = (*cmux.Pane).ListTabs
	var _ func(*cmux.Pane, context.Context, string) ([]*cmux.Tab, error) = (*cmux.Pane).FindTabsByName
	var _ func(*cmux.Session, context.Context, cmux.TerminalListOptions) ([]*cmux.Terminal, error) = (*cmux.Session).ListTerminals
	var _ func(*cmux.Session, context.Context, string) ([]*cmux.Terminal, error) = (*cmux.Session).FindTerminalsByName
	var _ func(*cmux.Session, context.Context, cmux.BrowserListOptions) ([]*cmux.Browser, error) = (*cmux.Session).ListBrowsers
	var _ func(*cmux.Session, context.Context, string) ([]*cmux.Browser, error) = (*cmux.Session).FindBrowsersByName
	var _ func(*cmux.Session, cmux.Selector[cmux.TerminalID]) *cmux.Terminal = (*cmux.Session).Terminal
	var _ func(*cmux.Session, cmux.Selector[cmux.BrowserID]) *cmux.Browser = (*cmux.Session).Browser
}

func TestCatalogResultMethodsCompileForExternalConsumers(t *testing.T) {
	var _ string = (cmux.ConfirmationRequiredDetails{}).ConfirmationToken
	var _ func(*cmux.Session, context.Context, cmux.SessionSnapshotOptions) (cmux.ResourceSnapshot, error) = (*cmux.Session).Snapshot
	var _ func(*cmux.Session, context.Context, string, cmux.SessionCreationResolveOptions) (cmux.CreationResolution, error) = (*cmux.Session).ResolveCreation
	var _ func(*cmux.Session, context.Context, cmux.SessionPingOptions) (cmux.PingResult, error) = (*cmux.Session).Ping
	var _ func(*cmux.Session, context.Context, cmux.SessionShutdownOptions) (cmux.MutationResult[cmux.ShutdownResult], error) = (*cmux.Session).Shutdown
	var _ func(*cmux.Session, context.Context, cmux.SessionReloadConfigOptions) (cmux.MutationResult[cmux.ReloadConfigResult], error) = (*cmux.Session).ReloadConfig
	var _ func(*cmux.Session, context.Context, cmux.SessionTerminalDefaultsUpdateOptions) (cmux.MutationResult[cmux.TerminalDefaultsSnapshot], error) = (*cmux.Session).UpdateTerminalDefaults
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalScreenReadOptions) (cmux.TerminalScreenResult, error) = (*cmux.Terminal).ReadScreen
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalStateReadOptions) (cmux.TerminalStateResult, error) = (*cmux.Terminal).ReadState
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalHistoryReadOptions) (cmux.TerminalHistoryResult, error) = (*cmux.Terminal).ReadHistory
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalWaitOptions) (cmux.TerminalWaitResult, error) = (*cmux.Terminal).Wait
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalWaitExitOptions) (cmux.TerminalWaitExitResult, error) = (*cmux.Terminal).WaitExit
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalCopyOptions) (cmux.TerminalCopyResult, error) = (*cmux.Terminal).Copy
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalProcessGetOptions) (cmux.ProcessInfoResult, error) = (*cmux.Terminal).Process
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalViewerResizeOptions) (cmux.ViewerResizeResult, error) = (*cmux.Terminal).ResizeViewer
	var _ func(*cmux.Browser, context.Context, cmux.BrowserViewerResizeOptions) (cmux.BrowserViewerResizeResult, error) = (*cmux.Browser).ResizeViewer
	var _ func(*cmux.ConnectedClient, context.Context, cmux.ConnectedClientCellPixelsSetOptions) (cmux.CellPixelsResult, error) = (*cmux.ConnectedClient).SetCellPixels
	var _ func(*cmux.Workspace, context.Context, cmux.WorkspaceRenameOptions) (cmux.MutationResult[*cmux.Workspace], error) = (*cmux.Workspace).Rename
	var _ func(*cmux.Screen, context.Context, cmux.ScreenRenameOptions) (cmux.MutationResult[*cmux.Screen], error) = (*cmux.Screen).Rename
	var _ func(*cmux.Pane, context.Context, cmux.PaneRenameOptions) (cmux.MutationResult[*cmux.Pane], error) = (*cmux.Pane).Rename
	var _ func(*cmux.Tab, context.Context, cmux.TabRenameOptions) (cmux.MutationResult[*cmux.Tab], error) = (*cmux.Tab).Rename
	var _ func(*cmux.Terminal, context.Context, cmux.TerminalMoveOptions) (cmux.MutationResult[*cmux.Terminal], error) = (*cmux.Terminal).Move
	var _ func(*cmux.Browser, context.Context, cmux.BrowserNavigateOptions) (cmux.MutationResult[*cmux.Browser], error) = (*cmux.Browser).Navigate
	var _ func(*cmux.PairingRequest, context.Context, cmux.PairingRequestResolveOptions) (cmux.MutationResult[*cmux.PairingRequest], error) = (*cmux.PairingRequest).Resolve
	var _ func(*cmux.FrontendProjection, context.Context, cmux.FrontendProjectionPutOptions) (cmux.MutationResult[*cmux.FrontendProjection], error) = (*cmux.FrontendProjection).Put
	var _ func(*cmux.Session, context.Context, cmux.AgentReportOptions) (cmux.MutationResult[*cmux.Agent], error) = (*cmux.Session).ReportAgent
	var _ func(*cmux.SidebarView, context.Context, cmux.SidebarViewResizeOptions) (cmux.MutationResult[*cmux.SidebarView], error) = (*cmux.SidebarView).Resize
}

func externalConsumerCompiles(
	client *cmux.Client,
	highLevel cmux.WorkspaceID,
	lowLevel *raw.Client,
) {
	_ = client.Machine(cmux.SelectCurrent[cmux.MachineID]()).
		Session(cmux.SelectCurrent[cmux.SessionID]()).
		Workspace(cmux.SelectID(highLevel))
	_, _ = lowLevel.Identify(context.Background())
}
