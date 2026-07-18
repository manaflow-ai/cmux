package cmux

import (
	"encoding/json"
	"fmt"
)

const (
	CanonicalTopologySnapshotCapability = "canonical-topology-snapshot-v1"
	StableEntityUUIDCapability          = "stable-entity-uuid-v1"
	TopologyResumeCapability            = "topology-resume-v1"
)

var TopologyV8Capabilities = []string{
	CanonicalTopologySnapshotCapability,
	StableEntityUUIDCapability,
	TopologyResumeCapability,
}

type UUID string

func ParseUUID(value string) (UUID, error) {
	if len(value) != 36 {
		return "", fmt.Errorf("invalid lowercase UUID %q", value)
	}
	for index, char := range []byte(value) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if char != '-' {
				return "", fmt.Errorf("invalid lowercase UUID %q", value)
			}
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return "", fmt.Errorf("invalid lowercase UUID %q", value)
		}
	}
	return UUID(value), nil
}

func (u *UUID) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	parsed, err := ParseUUID(value)
	if err != nil {
		return err
	}
	*u = parsed
	return nil
}

func (u UUID) String() string { return string(u) }

type IdentifyResult struct {
	App                       string   `json:"app"`
	Version                   string   `json:"version"`
	Protocol                  uint32   `json:"protocol"`
	ProtocolMin               *uint32  `json:"protocol_min"`
	ProtocolMax               *uint32  `json:"protocol_max"`
	Capabilities              []string `json:"capabilities"`
	Session                   string   `json:"session"`
	SessionID                 *UUID    `json:"session_id"`
	DaemonInstanceID          *UUID    `json:"daemon_instance_id"`
	TopologyRevision          *uint64  `json:"topology_revision"`
	CanonicalTopologyRevision *uint64  `json:"canonical_topology_revision"`
	PID                       uint32   `json:"pid"`
}

func (r IdentifyResult) SupportsTopologyV8() bool {
	if r.Protocol < 8 {
		return false
	}
	for _, required := range TopologyV8Capabilities {
		found := false
		for _, actual := range r.Capabilities {
			if actual == required {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

func (r IdentifyResult) TopologyCursor() (TopologyCursor, bool) {
	if r.DaemonInstanceID == nil || r.SessionID == nil || r.CanonicalTopologyRevision == nil {
		return TopologyCursor{}, false
	}
	return TopologyCursor{
		DaemonInstanceID: *r.DaemonInstanceID,
		SessionID:        *r.SessionID,
		Revision:         *r.CanonicalTopologyRevision,
	}, true
}

type PingResult struct {
	OK                        bool     `json:"ok"`
	Version                   string   `json:"version"`
	Protocol                  uint32   `json:"protocol"`
	ProtocolMin               *uint32  `json:"protocol_min"`
	ProtocolMax               *uint32  `json:"protocol_max"`
	Capabilities              []string `json:"capabilities"`
	Session                   *string  `json:"session"`
	SessionID                 *UUID    `json:"session_id"`
	DaemonInstanceID          *UUID    `json:"daemon_instance_id"`
	TopologyRevision          *uint64  `json:"topology_revision"`
	CanonicalTopologyRevision *uint64  `json:"canonical_topology_revision"`
	PID                       *uint32  `json:"pid"`
}

type TopologyAuthority struct {
	DaemonInstanceID UUID `json:"daemon_instance_id"`
	SessionID        UUID `json:"session_id"`
}

type TopologyCursor struct {
	DaemonInstanceID UUID   `json:"daemon_instance_id"`
	SessionID        UUID   `json:"session_id"`
	Revision         uint64 `json:"revision"`
}

type CanonicalTopology struct {
	Workspaces []CanonicalWorkspace `json:"workspaces"`
}

type CanonicalWorkspace struct {
	ID      uint64            `json:"id"`
	UUID    UUID              `json:"uuid"`
	Name    string            `json:"name"`
	Screens []CanonicalScreen `json:"screens"`
}

type CanonicalScreen struct {
	ID     uint64          `json:"id"`
	UUID   UUID            `json:"uuid"`
	Name   *string         `json:"name"`
	Layout CanonicalLayout `json:"layout"`
	Panes  []CanonicalPane `json:"panes"`
}

type CanonicalLayout struct {
	Type     string           `json:"type"`
	Pane     *uint64          `json:"pane,omitempty"`
	PaneUUID *UUID            `json:"pane_uuid,omitempty"`
	Dir      *string          `json:"dir,omitempty"`
	Ratio    *float32         `json:"ratio,omitempty"`
	A        *CanonicalLayout `json:"a,omitempty"`
	B        *CanonicalLayout `json:"b,omitempty"`
}

type CanonicalPane struct {
	ID   uint64         `json:"id"`
	UUID UUID           `json:"uuid"`
	Name *string        `json:"name"`
	Tabs []CanonicalTab `json:"tabs"`
}

type CanonicalTab struct {
	ID   uint64  `json:"id"`
	UUID UUID    `json:"uuid"`
	Kind string  `json:"kind"`
	Name *string `json:"name"`
}

type TopologySnapshot struct {
	TopologyAuthority
	Revision uint64            `json:"revision"`
	Topology CanonicalTopology `json:"topology"`
}

func (s TopologySnapshot) Cursor() TopologyCursor {
	return TopologyCursor{
		DaemonInstanceID: s.DaemonInstanceID,
		SessionID:        s.SessionID,
		Revision:         s.Revision,
	}
}

type TopologyTargets struct {
	Workspaces []UUID `json:"workspaces"`
	Screens    []UUID `json:"screens"`
	Panes      []UUID `json:"panes"`
	Surfaces   []UUID `json:"surfaces"`
}

type TopologyOperation string

const (
	TopologyWorkspaceCreated  TopologyOperation = "workspace-created"
	TopologyScreenCreated     TopologyOperation = "screen-created"
	TopologyPaneSplit         TopologyOperation = "pane-split"
	TopologySurfaceAttached   TopologyOperation = "surface-attached"
	TopologySurfaceClosed     TopologyOperation = "surface-closed"
	TopologyPaneClosed        TopologyOperation = "pane-closed"
	TopologyScreenClosed      TopologyOperation = "screen-closed"
	TopologyWorkspaceClosed   TopologyOperation = "workspace-closed"
	TopologyWorkspaceRenamed  TopologyOperation = "workspace-renamed"
	TopologyScreenRenamed     TopologyOperation = "screen-renamed"
	TopologyPaneRenamed       TopologyOperation = "pane-renamed"
	TopologySurfaceRenamed    TopologyOperation = "surface-renamed"
	TopologySplitRatioChanged TopologyOperation = "split-ratio-changed"
	TopologyPanesSwapped      TopologyOperation = "panes-swapped"
	TopologyLayoutApplied     TopologyOperation = "layout-applied"
	TopologyTabMoved          TopologyOperation = "tab-moved"
	TopologyWorkspaceMoved    TopologyOperation = "workspace-moved"
)

type TopologyDelta struct {
	TopologyAuthority
	BaseRevision uint64            `json:"base_revision"`
	Revision     uint64            `json:"revision"`
	Operation    TopologyOperation `json:"operation"`
	Targets      TopologyTargets   `json:"targets"`
	Replacement  CanonicalTopology `json:"replacement"`
}

type TopologyResnapshotReason string

const (
	TopologyStaleDaemon    TopologyResnapshotReason = "stale-daemon"
	TopologyStaleSession   TopologyResnapshotReason = "stale-session"
	TopologyRevisionAhead  TopologyResnapshotReason = "revision-ahead"
	TopologyHistoryGap     TopologyResnapshotReason = "history-gap"
	TopologyReplayTooLarge TopologyResnapshotReason = "replay-too-large"
	TopologySlowConsumer   TopologyResnapshotReason = "slow-consumer"
)

type TopologyResnapshotRequired struct {
	TopologyAuthority
	Status          string                   `json:"status,omitempty"`
	CurrentRevision *uint64                  `json:"current_revision"`
	Reason          TopologyResnapshotReason `json:"reason"`
}

type TopologySubscribed struct {
	TopologyAuthority
	Status          string `json:"status"`
	FromRevision    uint64 `json:"from_revision"`
	CurrentRevision uint64 `json:"current_revision"`
	Replayed        uint   `json:"replayed"`
}

type SurfaceResult struct {
	Surface uint64 `json:"surface"`
}

type ReadScreenResult struct {
	Text string `json:"text"`
}

type ProcessInfoResult struct {
	PID     *uint32  `json:"pid"`
	Command []string `json:"command"`
	CWD     *string  `json:"cwd"`
	TTY     *string  `json:"tty"`
}

type EnsureTerminalEnvironment struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type EnsureTerminalOptions struct {
	CWD              *string                     `json:"cwd,omitempty"`
	Argv             []string                    `json:"argv,omitempty"`
	Command          *string                     `json:"command,omitempty"`
	Environment      []EnsureTerminalEnvironment `json:"env,omitempty"`
	InitialInput     *string                     `json:"initial_input,omitempty"`
	WaitAfterCommand bool                        `json:"wait_after_command"`
}

type EnsureTerminalResult struct {
	Created       bool   `json:"created"`
	Workspace     uint64 `json:"workspace"`
	WorkspaceUUID UUID   `json:"workspace_uuid"`
	Screen        uint64 `json:"screen"`
	ScreenUUID    UUID   `json:"screen_uuid"`
	Pane          uint64 `json:"pane"`
	PaneUUID      UUID   `json:"pane_uuid"`
	Surface       uint64 `json:"surface"`
	SurfaceUUID   UUID   `json:"surface_uuid"`
}

type ReparentTerminalResult struct {
	Moved         bool   `json:"moved"`
	Workspace     uint64 `json:"workspace"`
	WorkspaceUUID UUID   `json:"workspace_uuid"`
	Screen        uint64 `json:"screen"`
	ScreenUUID    UUID   `json:"screen_uuid"`
	Pane          uint64 `json:"pane"`
	PaneUUID      UUID   `json:"pane_uuid"`
	Surface       uint64 `json:"surface"`
	SurfaceUUID   UUID   `json:"surface_uuid"`
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

type TopologyDeltaEvent struct {
	TopologyDelta
}

func (TopologyDeltaEvent) EventName() string    { return "topology-delta" }
func (TopologyDeltaEvent) topologyStreamEvent() {}

type TopologyResnapshotRequiredEvent struct {
	TopologyResnapshotRequired
}

func (TopologyResnapshotRequiredEvent) EventName() string {
	return "topology-resnapshot-required"
}

func (TopologyResnapshotRequiredEvent) topologyStreamEvent() {}

type TopologyStreamEvent interface {
	Event
	topologyStreamEvent()
}
