package cmux

import "encoding/json"

type IdentifyResult struct {
	App      string `json:"app"`
	Version  string `json:"version"`
	Protocol uint32 `json:"protocol"`
	Session  string `json:"session"`
	PID      uint32 `json:"pid"`
}

type IdentifyDetails struct {
	App           string   `json:"app"`
	Version       string   `json:"version"`
	BuildCommit   *string  `json:"build_commit"`
	GhosttyCommit *string  `json:"ghostty_commit"`
	Protocol      uint32   `json:"protocol"`
	Capabilities  []string `json:"capabilities"`
	Session       string   `json:"session"`
	PID           uint32   `json:"pid"`
}

type SurfaceResult struct {
	Surface uint64 `json:"surface"`
}

type ReadScreenResult struct {
	Text string `json:"text"`
}

type VtStateResult struct {
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
	Data string `json:"data"`
}

type ResizeSurfaceResult struct {
	Accepted      bool    `json:"accepted"`
	ReservationID *uint64 `json:"reservation_id"`
}

func (r *ResizeSurfaceResult) UnmarshalJSON(data []byte) error {
	type wireResult ResizeSurfaceResult
	decoded := wireResult{Accepted: true}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*r = ResizeSurfaceResult(decoded)
	return nil
}

type Tree struct {
	WorkspaceRevision uint64      `json:"workspace_revision"`
	PaneRevision      *uint64     `json:"pane_revision"`
	Workspaces        []Workspace `json:"workspaces"`
}

type Workspace struct {
	ID      uint64   `json:"id"`
	Key     string   `json:"key"`
	Name    string   `json:"name"`
	Active  bool     `json:"active"`
	Screens []Screen `json:"screens"`
}

type Screen struct {
	ID         uint64  `json:"id"`
	Name       *string `json:"name"`
	Active     bool    `json:"active"`
	ActivePane uint64  `json:"active_pane"`
	Layout     any     `json:"layout"`
	Panes      []Pane  `json:"panes"`
}

type Pane struct {
	ID        uint64  `json:"id"`
	Name      *string `json:"name"`
	ActiveTab uint    `json:"active_tab"`
	FocusedAt uint64  `json:"focused_at,omitempty"`
	Tabs      []Tab   `json:"tabs"`
	Dead      bool    `json:"dead"`
}

type Tab struct {
	Surface       uint64  `json:"surface"`
	Kind          string  `json:"kind"`
	BrowserSource *string `json:"browser_source"`
	Name          *string `json:"name"`
	Title         string  `json:"title"`
	Size          *Size   `json:"size"`
	Dead          bool    `json:"dead"`
}

type Size struct {
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

type SendOptions struct {
	Text        *string
	Bytes       []byte
	Base64Bytes string
}

type NewTabOptions struct {
	Pane *uint64 `json:"pane,omitempty"`
	Cwd  *string `json:"cwd,omitempty"`
	Cols *uint16 `json:"cols,omitempty"`
	Rows *uint16 `json:"rows,omitempty"`
}

type NewBrowserTabOptions struct {
	Pane *uint64 `json:"pane,omitempty"`
	Cols *uint16 `json:"cols,omitempty"`
	Rows *uint16 `json:"rows,omitempty"`
}

type NewWorkspaceOptions struct {
	Name *string `json:"name,omitempty"`
	Cols *uint16 `json:"cols,omitempty"`
	Rows *uint16 `json:"rows,omitempty"`
}

type CreateWorkspaceOptions struct {
	Name             *string `json:"name,omitempty"`
	Key              *string `json:"key,omitempty"`
	ExpectedRevision *uint64 `json:"expected_revision,omitempty"`
}

type WorkspacePlacement struct {
	Workspace         uint64 `json:"workspace"`
	Key               string `json:"key"`
	Index             uint   `json:"index"`
	WorkspaceRevision uint64 `json:"workspace_revision"`
}

type CreateTerminalOptions struct {
	Workspace *uint64  `json:"workspace,omitempty"`
	Key       *string  `json:"key,omitempty"`
	Argv      []string `json:"argv"`
	Command   *string  `json:"command,omitempty"`
	Cwd       *string  `json:"cwd,omitempty"`
	Name      *string  `json:"name,omitempty"`
	Cols      *uint16  `json:"cols,omitempty"`
	Rows      *uint16  `json:"rows,omitempty"`
}

type TerminalPlacement struct {
	Surface   uint64 `json:"surface"`
	Pane      uint64 `json:"pane"`
	Screen    uint64 `json:"screen"`
	Workspace uint64 `json:"workspace"`
	Key       string `json:"key"`
}

type WorkspaceSelectorOptions struct {
	Workspace        *uint64 `json:"workspace,omitempty"`
	Key              *string `json:"key,omitempty"`
	ExpectedRevision *uint64 `json:"expected_revision,omitempty"`
}

type WorkspaceMutation struct {
	Workspace         uint64 `json:"workspace"`
	Key               string `json:"key"`
	WorkspaceRevision uint64 `json:"workspace_revision"`
}

type NewScreenOptions struct {
	Workspace *uint64 `json:"workspace,omitempty"`
	Cols      *uint16 `json:"cols,omitempty"`
	Rows      *uint16 `json:"rows,omitempty"`
}

type NewPaneOptions struct {
	Cols *uint16 `json:"cols,omitempty"`
	Rows *uint16 `json:"rows,omitempty"`
}

type SplitOptions struct {
	Cols *uint16 `json:"cols,omitempty"`
	Rows *uint16 `json:"rows,omitempty"`
}

type SelectOptions struct {
	Index *uint `json:"index,omitempty"`
	Delta *int  `json:"delta,omitempty"`
}

type SelectTabOptions struct {
	Pane  *uint64 `json:"pane,omitempty"`
	Index *uint   `json:"index,omitempty"`
	Delta *int    `json:"delta,omitempty"`
}

type Event interface {
	EventName() string
}

type TreeChangedEvent struct{}

func (TreeChangedEvent) EventName() string { return "tree-changed" }

type LayoutChangedEvent struct {
	Screen uint64 `json:"screen"`
}

func (LayoutChangedEvent) EventName() string { return "layout-changed" }

type EmptyEvent struct{}

func (EmptyEvent) EventName() string { return "empty" }

type OverflowEvent struct {
	Error   string  `json:"error"`
	Scope   *string `json:"scope"`
	Surface *uint64 `json:"surface"`
}

func (OverflowEvent) EventName() string { return "overflow" }

type SurfaceEvent struct {
	Event   string `json:"event"`
	Surface uint64 `json:"surface"`
}

func (e SurfaceEvent) EventName() string { return e.Event }

type TitleChangedEvent struct {
	Surface uint64  `json:"surface"`
	Title   *string `json:"title"`
}

func (TitleChangedEvent) EventName() string { return "title-changed" }

type SurfaceResizedEvent struct {
	Surface       uint64  `json:"surface"`
	Cols          uint16  `json:"cols"`
	Rows          uint16  `json:"rows"`
	ReservationID *uint64 `json:"reservation_id"`
}

func (SurfaceResizedEvent) EventName() string { return "surface-resized" }

type SurfaceResizeFailedEvent struct {
	Surface       uint64  `json:"surface"`
	Cols          uint16  `json:"cols"`
	Rows          uint16  `json:"rows"`
	Error         string  `json:"error"`
	RetryAfterMS  *uint64 `json:"retry_after_ms"`
	ReservationID *uint64 `json:"reservation_id"`
}

func (SurfaceResizeFailedEvent) EventName() string { return "surface-resize-failed" }

type VtStateEvent struct {
	Surface uint64 `json:"surface"`
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
	Data    string `json:"data"`
}

func (VtStateEvent) EventName() string { return "vt-state" }

type OutputEvent struct {
	Surface uint64 `json:"surface"`
	Data    string `json:"data"`
}

func (OutputEvent) EventName() string { return "output" }

type ResizedEvent struct {
	Surface uint64 `json:"surface"`
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
	Replay  string `json:"replay"`
}

func (ResizedEvent) EventName() string { return "resized" }

type DetachedEvent struct {
	Surface uint64 `json:"surface"`
}

func (DetachedEvent) EventName() string { return "detached" }

type UnknownEvent struct {
	Name string
	Raw  map[string]any
}

func (e UnknownEvent) EventName() string { return e.Name }
