package cmux_test

import (
	"context"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

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
