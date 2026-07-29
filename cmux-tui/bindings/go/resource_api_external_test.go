package cmux_test

import (
	"context"
	"testing"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

func TestResourceCollectionsExposePointerHandles(t *testing.T) {
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
