package cmux

type IdentifyResult struct {
	App      string `json:"app"`
	Version  string `json:"version"`
	Protocol uint32 `json:"protocol"`
	Session  string `json:"session"`
	PID      uint32 `json:"pid"`
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

type Tree struct {
	Workspaces []Workspace `json:"workspaces"`
}

type Workspace struct {
	ID      uint64   `json:"id"`
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

type NewScreenOptions struct {
	Workspace *uint64 `json:"workspace,omitempty"`
	Cols      *uint16 `json:"cols,omitempty"`
	Rows      *uint16 `json:"rows,omitempty"`
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

type EmptyEvent struct{}

func (EmptyEvent) EventName() string { return "empty" }

type SurfaceEvent struct {
	Event   string `json:"event"`
	Surface uint64 `json:"surface"`
}

func (e SurfaceEvent) EventName() string { return e.Event }

type SurfaceResizedEvent struct {
	Surface uint64 `json:"surface"`
	Cols    uint16 `json:"cols"`
	Rows    uint16 `json:"rows"`
}

func (SurfaceResizedEvent) EventName() string { return "surface-resized" }

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
