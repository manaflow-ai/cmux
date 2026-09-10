package cmux

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"reflect"
	"strings"
	"sync"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev2"
)

type MachineSnapshot struct {
	ID          MachineID            `json:"id"`
	Name        string               `json:"name"`
	Origin      string               `json:"origin"`
	Status      string               `json:"status"`
	Connectable bool                 `json:"connectable"`
	Deleted     bool                 `json:"deleted"`
	Recoverable bool                 `json:"recoverable"`
	Extra       map[string]JSONValue `json:"extra,omitempty"`
}

type SessionSnapshot struct {
	ID         SessionID            `json:"id"`
	MachineID  MachineID            `json:"machine_id"`
	Name       *string              `json:"name,omitempty"`
	Generation string               `json:"generation"`
	Revision   Decimal              `json:"revision"`
	Connected  bool                 `json:"connected"`
	Extra      map[string]JSONValue `json:"extra,omitempty"`
}

type WorkspaceSnapshot struct {
	ID        WorkspaceID          `json:"id"`
	SessionID SessionID            `json:"session_id"`
	Name      string               `json:"name"`
	Index     uint32               `json:"index"`
	Focused   bool                 `json:"focused"`
	Extra     map[string]JSONValue `json:"extra,omitempty"`
}

type LayoutDirection string

const (
	LayoutHorizontal LayoutDirection = "horizontal"
	LayoutVertical   LayoutDirection = "vertical"
)

type LayoutNode interface {
	layoutNode()
}

type LayoutLeaf struct {
	Kind        string  `json:"kind"`
	PaneID      PaneID  `json:"pane_id"`
	TabIDs      []TabID `json:"tab_ids"`
	ActiveTabID *TabID  `json:"active_tab_id,omitempty"`
}

func (LayoutLeaf) layoutNode() {}

type LayoutSplit struct {
	Kind      string          `json:"kind"`
	SplitID   SplitID         `json:"split_id"`
	Direction LayoutDirection `json:"direction"`
	Ratio     float64         `json:"ratio"`
	First     LayoutNode      `json:"first"`
	Second    LayoutNode      `json:"second"`
}

func (LayoutSplit) layoutNode() {}

type LayoutStack struct {
	Kind           string   `json:"kind"`
	PaneIDs        []PaneID `json:"pane_ids"`
	ExpandedPaneID PaneID   `json:"expanded_pane_id"`
}

func (LayoutStack) layoutNode() {}

type LayoutColumn struct {
	ColumnID SplitID    `json:"column_id"`
	Width    float64    `json:"width"`
	Root     LayoutNode `json:"root"`
}

type LayoutViewport struct {
	Kind      string         `json:"kind"`
	BaseWidth float64        `json:"base_width"`
	Columns   []LayoutColumn `json:"columns"`
}

func (LayoutViewport) layoutNode() {}

type LayoutDocument struct {
	Version      uint32               `json:"version"`
	ScreenID     ScreenID             `json:"screen_id"`
	ActivePaneID PaneID               `json:"active_pane_id"`
	ZoomedPaneID *PaneID              `json:"zoomed_pane_id"`
	Root         LayoutNode           `json:"root"`
	Extra        map[string]JSONValue `json:"extra,omitempty"`
}

func (d *LayoutDocument) UnmarshalJSON(data []byte) error {
	var wire struct {
		Version      *uint32         `json:"version"`
		ScreenID     *ScreenID       `json:"screen_id"`
		ActivePaneID *PaneID         `json:"active_pane_id"`
		ZoomedPaneID json.RawMessage `json:"zoomed_pane_id"`
		Root         json.RawMessage `json:"root"`
		Extra        json.RawMessage `json:"extra,omitempty"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return err
	}
	if wire.Version == nil || wire.ScreenID == nil || wire.ActivePaneID == nil ||
		len(wire.ZoomedPaneID) == 0 || len(wire.Root) == 0 {
		return fmt.Errorf(
			"layout document requires version, screen_id, active_pane_id, zoomed_pane_id, and root",
		)
	}
	var zoomedPaneID *PaneID
	if string(wire.ZoomedPaneID) != "null" {
		var value PaneID
		if err := json.Unmarshal(wire.ZoomedPaneID, &value); err != nil {
			return fmt.Errorf("layout zoomed_pane_id: %w", err)
		}
		zoomedPaneID = &value
	}
	root, err := decodeLayoutNode(wire.Root)
	if err != nil {
		return err
	}
	var extra map[string]JSONValue
	if len(wire.Extra) > 0 {
		decoder := json.NewDecoder(bytes.NewReader(wire.Extra))
		decoder.UseNumber()
		if err := decoder.Decode(&extra); err != nil {
			return fmt.Errorf("layout extra must be a JSON object: %w", err)
		}
		if extra == nil {
			return fmt.Errorf("layout extra must be a JSON object")
		}
	}
	*d = LayoutDocument{
		Version: *wire.Version, ScreenID: *wire.ScreenID,
		ActivePaneID: *wire.ActivePaneID, ZoomedPaneID: zoomedPaneID,
		Root: root, Extra: extra,
	}
	return nil
}

func decodeLayoutNode(data []byte) (LayoutNode, error) {
	var discriminator struct {
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(data, &discriminator); err != nil {
		return nil, fmt.Errorf("layout node must be an object: %w", err)
	}
	switch discriminator.Kind {
	case "leaf":
		var wire struct {
			Kind        string   `json:"kind"`
			PaneID      *PaneID  `json:"pane_id"`
			TabIDs      *[]TabID `json:"tab_ids"`
			ActiveTabID *TabID   `json:"active_tab_id,omitempty"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.PaneID == nil || wire.TabIDs == nil {
			return nil, fmt.Errorf("layout leaf requires pane_id and tab_ids")
		}
		return LayoutLeaf{
			Kind: "leaf", PaneID: *wire.PaneID,
			TabIDs:      append([]TabID(nil), (*wire.TabIDs)...),
			ActiveTabID: wire.ActiveTabID,
		}, nil
	case "split":
		var wire struct {
			Kind      string           `json:"kind"`
			SplitID   *SplitID         `json:"split_id"`
			Direction *LayoutDirection `json:"direction"`
			Ratio     *float64         `json:"ratio"`
			First     json.RawMessage  `json:"first"`
			Second    json.RawMessage  `json:"second"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.SplitID == nil || wire.Direction == nil || wire.Ratio == nil ||
			len(wire.First) == 0 || len(wire.Second) == 0 {
			return nil, fmt.Errorf(
				"layout split requires split_id, direction, ratio, first, and second",
			)
		}
		if *wire.Direction != LayoutHorizontal && *wire.Direction != LayoutVertical {
			return nil, fmt.Errorf("invalid layout split direction %q", *wire.Direction)
		}
		if math.IsNaN(*wire.Ratio) || math.IsInf(*wire.Ratio, 0) ||
			*wire.Ratio <= 0 || *wire.Ratio >= 1 {
			return nil, fmt.Errorf("layout split ratio must be finite and between 0 and 1")
		}
		first, err := decodeLayoutNode(wire.First)
		if err != nil {
			return nil, fmt.Errorf("layout split first: %w", err)
		}
		second, err := decodeLayoutNode(wire.Second)
		if err != nil {
			return nil, fmt.Errorf("layout split second: %w", err)
		}
		return LayoutSplit{
			Kind: "split", SplitID: *wire.SplitID, Direction: *wire.Direction,
			Ratio: *wire.Ratio, First: first, Second: second,
		}, nil
	case "stack":
		var wire struct {
			Kind           string    `json:"kind"`
			PaneIDs        *[]PaneID `json:"pane_ids"`
			ExpandedPaneID *PaneID   `json:"expanded_pane_id"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.PaneIDs == nil || len(*wire.PaneIDs) == 0 ||
			wire.ExpandedPaneID == nil {
			return nil, fmt.Errorf(
				"layout stack requires non-empty pane_ids and expanded_pane_id",
			)
		}
		found := false
		for _, paneID := range *wire.PaneIDs {
			if paneID == *wire.ExpandedPaneID {
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf(
				"layout stack expanded_pane_id must be present in pane_ids",
			)
		}
		return LayoutStack{
			Kind: "stack", PaneIDs: append([]PaneID(nil), (*wire.PaneIDs)...),
			ExpandedPaneID: *wire.ExpandedPaneID,
		}, nil
	case "viewport":
		var wire struct {
			Kind      string             `json:"kind"`
			BaseWidth *float64           `json:"base_width"`
			Columns   *[]json.RawMessage `json:"columns"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.BaseWidth == nil || wire.Columns == nil || len(*wire.Columns) == 0 {
			return nil, fmt.Errorf(
				"layout viewport requires base_width and non-empty columns",
			)
		}
		if !validLayoutWidth(*wire.BaseWidth) {
			return nil, fmt.Errorf(
				"layout viewport base_width must be finite and between 0.1 and 1",
			)
		}
		columns := make([]LayoutColumn, 0, len(*wire.Columns))
		for index, rawColumn := range *wire.Columns {
			column, err := decodeLayoutColumn(rawColumn)
			if err != nil {
				return nil, fmt.Errorf("layout viewport column %d: %w", index, err)
			}
			columns = append(columns, column)
		}
		return LayoutViewport{
			Kind: "viewport", BaseWidth: *wire.BaseWidth, Columns: columns,
		}, nil
	default:
		return nil, fmt.Errorf("unsupported layout node kind %q", discriminator.Kind)
	}
}

func decodeLayoutColumn(data []byte) (LayoutColumn, error) {
	var wire struct {
		ColumnID *SplitID        `json:"column_id"`
		Width    *float64        `json:"width"`
		Root     json.RawMessage `json:"root"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return LayoutColumn{}, err
	}
	if wire.ColumnID == nil || wire.Width == nil || len(wire.Root) == 0 {
		return LayoutColumn{}, fmt.Errorf(
			"layout column requires column_id, width, and root",
		)
	}
	if !validLayoutWidth(*wire.Width) {
		return LayoutColumn{}, fmt.Errorf(
			"layout column width must be finite and between 0.1 and 1",
		)
	}
	root, err := decodeLayoutNode(wire.Root)
	if err != nil {
		return LayoutColumn{}, err
	}
	return LayoutColumn{
		ColumnID: *wire.ColumnID, Width: *wire.Width, Root: root,
	}, nil
}

func validLayoutWidth(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) &&
		value >= 0.1 && value <= 1
}

type ScreenSnapshot struct {
	ID          ScreenID             `json:"id"`
	WorkspaceID WorkspaceID          `json:"workspace_id"`
	Name        *string              `json:"name"`
	Index       uint32               `json:"index"`
	Focused     bool                 `json:"focused"`
	Layout      LayoutDocument       `json:"layout"`
	Extra       map[string]JSONValue `json:"extra,omitempty"`
}

type PaneSnapshot struct {
	ID       PaneID               `json:"id"`
	ScreenID ScreenID             `json:"screen_id"`
	Name     *string              `json:"name"`
	Focused  bool                 `json:"focused"`
	Zoomed   bool                 `json:"zoomed"`
	Extra    map[string]JSONValue `json:"extra,omitempty"`
}

type TabSnapshot struct {
	ID          TabID                `json:"id"`
	PaneID      PaneID               `json:"pane_id"`
	Name        *string              `json:"name"`
	Index       uint32               `json:"index"`
	Focused     bool                 `json:"focused"`
	ContentKind string               `json:"content_kind"`
	ContentID   TabContentID         `json:"-"`
	Extra       map[string]JSONValue `json:"extra,omitempty"`
}

func (s *TabSnapshot) UnmarshalJSON(data []byte) error {
	var wire struct {
		ID          TabID                `json:"id"`
		PaneID      PaneID               `json:"pane_id"`
		Name        json.RawMessage      `json:"name"`
		Index       uint32               `json:"index"`
		Focused     bool                 `json:"focused"`
		ContentKind string               `json:"content_kind"`
		ContentID   string               `json:"content_id"`
		Extra       map[string]JSONValue `json:"extra,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&wire); err != nil {
		return err
	}
	if wire.Name == nil {
		return fmt.Errorf("tab snapshot omitted required nullable name")
	}
	var name *string
	if string(wire.Name) != "null" {
		var value string
		if err := json.Unmarshal(wire.Name, &value); err != nil {
			return fmt.Errorf("tab snapshot name must be string or null: %w", err)
		}
		name = &value
	}
	var contentID TabContentID
	switch wire.ContentKind {
	case "terminal":
		value, err := ParseTerminalID(wire.ContentID)
		if err != nil {
			return fmt.Errorf("tab terminal content_id: %w", err)
		}
		contentID = value
	case "browser":
		value, err := ParseBrowserID(wire.ContentID)
		if err != nil {
			return fmt.Errorf("tab browser content_id: %w", err)
		}
		contentID = value
	default:
		return fmt.Errorf("tab content_kind must be terminal or browser")
	}
	*s = TabSnapshot{
		ID: wire.ID, PaneID: wire.PaneID, Name: name, Index: wire.Index,
		Focused: wire.Focused, ContentKind: wire.ContentKind,
		ContentID: contentID, Extra: wire.Extra,
	}
	return nil
}

func (s TabSnapshot) MarshalJSON() ([]byte, error) {
	if s.ContentID == nil {
		return nil, fmt.Errorf("tab snapshot content ID is required")
	}
	return json.Marshal(struct {
		ID          TabID                `json:"id"`
		PaneID      PaneID               `json:"pane_id"`
		Name        *string              `json:"name"`
		Index       uint32               `json:"index"`
		Focused     bool                 `json:"focused"`
		ContentKind string               `json:"content_kind"`
		ContentID   string               `json:"content_id"`
		Extra       map[string]JSONValue `json:"extra,omitempty"`
	}{
		ID: s.ID, PaneID: s.PaneID, Name: s.Name, Index: s.Index,
		Focused: s.Focused, ContentKind: s.ContentKind,
		ContentID: s.ContentID.String(), Extra: s.Extra,
	})
}

type TerminalSnapshot struct {
	ID        TerminalID           `json:"id"`
	TabIDs    []TabID              `json:"tab_ids"`
	Title     string               `json:"title"`
	CWD       *string              `json:"cwd,omitempty"`
	Cols      uint16               `json:"cols"`
	Rows      uint16               `json:"rows"`
	Running   bool                 `json:"running"`
	Lifecycle TerminalLifecycle    `json:"lifecycle"`
	Exit      *TerminalExit        `json:"exit,omitempty"`
	Extra     map[string]JSONValue `json:"extra,omitempty"`
}

func (s *TerminalSnapshot) UnmarshalJSON(data []byte) error {
	var wire struct {
		ID        TerminalID           `json:"id"`
		TabID     json.RawMessage      `json:"tab_id"`
		TabIDs    json.RawMessage      `json:"tab_ids"`
		Title     string               `json:"title"`
		CWD       *string              `json:"cwd,omitempty"`
		Cols      uint16               `json:"cols"`
		Rows      uint16               `json:"rows"`
		Running   bool                 `json:"running"`
		Lifecycle TerminalLifecycle    `json:"lifecycle"`
		Exit      *TerminalExit        `json:"exit,omitempty"`
		Extra     map[string]JSONValue `json:"extra,omitempty"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return err
	}
	hasTabID := len(wire.TabID) > 0
	hasTabIDs := len(wire.TabIDs) > 0
	if !hasTabID && !hasTabIDs {
		return fmt.Errorf("terminal snapshot requires tab_ids or tab_id")
	}
	var legacyTabID *TabID
	if hasTabID && !bytes.Equal(bytes.TrimSpace(wire.TabID), []byte("null")) {
		var value TabID
		if err := strictDecode(wire.TabID, &value); err != nil {
			return fmt.Errorf("terminal tab_id: %w", err)
		}
		legacyTabID = &value
	}
	var tabIDs []TabID
	if hasTabIDs {
		if bytes.Equal(bytes.TrimSpace(wire.TabIDs), []byte("null")) {
			return fmt.Errorf("terminal tab_ids must be an array")
		}
		if err := strictDecode(wire.TabIDs, &tabIDs); err != nil {
			return fmt.Errorf("terminal tab_ids: %w", err)
		}
	} else if legacyTabID == nil {
		tabIDs = []TabID{}
	} else {
		tabIDs = []TabID{*legacyTabID}
	}
	if hasTabID &&
		((legacyTabID == nil) != (len(tabIDs) == 0) ||
			(legacyTabID != nil && *legacyTabID != tabIDs[0])) {
		return fmt.Errorf("terminal tab_id must be the first tab_ids item")
	}
	*s = TerminalSnapshot{
		ID: wire.ID, TabIDs: tabIDs, Title: wire.Title, CWD: wire.CWD,
		Cols: wire.Cols, Rows: wire.Rows, Running: wire.Running,
		Lifecycle: wire.Lifecycle, Exit: wire.Exit, Extra: wire.Extra,
	}
	return nil
}

type Size struct {
	Cols uint16 `json:"cols"`
	Rows uint16 `json:"rows"`
}

type PixelSize struct {
	WidthPX  uint32 `json:"width_px"`
	HeightPX uint32 `json:"height_px"`
}

type BrowserSnapshot struct {
	ID            BrowserID            `json:"id"`
	TabID         TabID                `json:"tab_id"`
	URL           string               `json:"url"`
	Title         string               `json:"title"`
	Loading       bool                 `json:"loading"`
	Source        string               `json:"source"`
	Status        string               `json:"status"`
	Error         *string              `json:"error"`
	FramesStalled bool                 `json:"frames_stalled"`
	Size          Size                 `json:"size"`
	Extra         map[string]JSONValue `json:"extra,omitempty"`
}

type ConnectedClientSnapshot struct {
	ID                  ConnectedClientID    `json:"id"`
	SessionID           SessionID            `json:"session_id"`
	Name                *string              `json:"name"`
	ClientKind          *string              `json:"client_kind"`
	Transport           string               `json:"transport"`
	ConnectedSeconds    Decimal              `json:"connected_seconds"`
	AttachedTerminalIDs []TerminalID         `json:"attached_terminal_ids"`
	Sizes               []ClientTerminalSize `json:"sizes"`
	Self                bool                 `json:"self"`
	Extra               map[string]JSONValue `json:"extra,omitempty"`
}

// ClientSnapshot is the catalog name for ConnectedClientSnapshot.
type ClientSnapshot = ConnectedClientSnapshot

type ClientTerminalSize struct {
	TerminalID    TerminalID `json:"terminal_id"`
	Cols          *uint16    `json:"cols"`
	Rows          *uint16    `json:"rows"`
	Participating bool       `json:"participating"`
}

type NotificationSnapshot struct {
	ID          NotificationID       `json:"id"`
	SessionID   SessionID            `json:"session_id"`
	Title       string               `json:"title"`
	Body        string               `json:"body"`
	Level       string               `json:"level"`
	TerminalID  *TerminalID          `json:"terminal_id,omitempty"`
	CreatedAtMS Decimal              `json:"created_at_ms"`
	Unread      bool                 `json:"unread"`
	Extra       map[string]JSONValue `json:"extra,omitempty"`
}

type AgentState string

const (
	AgentStateWorking AgentState = "working"
	AgentStateBlocked AgentState = "blocked"
	AgentStateIdle    AgentState = "idle"
	AgentStateDone    AgentState = "done"
	AgentStateUnknown AgentState = "unknown"
)

type AgentSource string

const (
	AgentSourceHook     AgentSource = "hook"
	AgentSourceSocket   AgentSource = "socket"
	AgentSourceDetected AgentSource = "detected"
)

// AgentReportSource excludes detected, which is server-owned discovery state.
type AgentReportSource string

const (
	AgentReportSourceHook   AgentReportSource = "hook"
	AgentReportSourceSocket AgentReportSource = "socket"
)

type AgentSnapshot struct {
	ID            AgentID              `json:"id"`
	SessionID     SessionID            `json:"session_id"`
	TerminalID    TerminalID           `json:"terminal_id"`
	State         AgentState           `json:"state"`
	Source        AgentSource          `json:"source"`
	UpdatedAtMS   Decimal              `json:"updated_at_ms"`
	SourceSession *string              `json:"source_session"`
	Extra         map[string]JSONValue `json:"extra,omitempty"`
}

type PairingRequestSnapshot struct {
	ID               PairingRequestID     `json:"id"`
	SessionID        SessionID            `json:"session_id"`
	Peer             string               `json:"peer"`
	Code             Secret               `json:"code"`
	ExpiresInSeconds Decimal              `json:"expires_in_seconds"`
	Status           string               `json:"status"`
	Extra            map[string]JSONValue `json:"extra,omitempty"`
}

type FrontendProjectionSnapshot struct {
	ID                 ProjectionID         `json:"id"`
	SessionID          SessionID            `json:"session_id"`
	FrontendID         string               `json:"frontend_id"`
	WindowID           string               `json:"window_id"`
	Generation         string               `json:"generation"`
	Projection         JSONValue            `json:"projection"`
	ProjectionRevision Decimal              `json:"projection_revision"`
	Extra              map[string]JSONValue `json:"extra,omitempty"`
}

type SidebarViewSnapshot struct {
	ID        SidebarViewID        `json:"id"`
	SessionID SessionID            `json:"session_id"`
	Cols      uint16               `json:"cols"`
	Rows      uint16               `json:"rows"`
	Running   bool                 `json:"running"`
	Extra     map[string]JSONValue `json:"extra,omitempty"`
}

type ResourceSnapshot struct {
	Machine             MachineSnapshot              `json:"machine"`
	Session             SessionSnapshot              `json:"session"`
	Workspaces          []WorkspaceSnapshot          `json:"workspaces"`
	Screens             []ScreenSnapshot             `json:"screens"`
	Panes               []PaneSnapshot               `json:"panes"`
	Tabs                []TabSnapshot                `json:"tabs"`
	Terminals           []TerminalSnapshot           `json:"terminals"`
	Browsers            []BrowserSnapshot            `json:"browsers"`
	Clients             []ClientSnapshot             `json:"clients"`
	Notifications       []NotificationSnapshot       `json:"notifications"`
	Agents              []AgentSnapshot              `json:"agents"`
	FrontendProjections []FrontendProjectionSnapshot `json:"frontend_projections"`
	SidebarViews        []SidebarViewSnapshot        `json:"sidebar_views"`
	Cursor              Cursor                       `json:"cursor"`
	Extra               map[string]JSONValue         `json:"extra,omitempty"`
}

type ResourceKind string

const (
	ResourceMachine            ResourceKind = "machine"
	ResourceSession            ResourceKind = "session"
	ResourceWorkspace          ResourceKind = "workspace"
	ResourceScreen             ResourceKind = "screen"
	ResourcePane               ResourceKind = "pane"
	ResourceTab                ResourceKind = "tab"
	ResourceTerminal           ResourceKind = "terminal"
	ResourceBrowser            ResourceKind = "browser"
	ResourceClient             ResourceKind = "client"
	ResourceNotification       ResourceKind = "notification"
	ResourceAgent              ResourceKind = "agent"
	ResourcePairingRequest     ResourceKind = "pairing_request"
	ResourceFrontendProjection ResourceKind = "frontend_projection"
	ResourceSidebarView        ResourceKind = "sidebar_view"
)

type ResourceChangeID interface {
	fmt.Stringer
}

type ResourceEntitySnapshot interface {
	resourceEntitySnapshot()
}

func (MachineSnapshot) resourceEntitySnapshot()            {}
func (SessionSnapshot) resourceEntitySnapshot()            {}
func (WorkspaceSnapshot) resourceEntitySnapshot()          {}
func (ScreenSnapshot) resourceEntitySnapshot()             {}
func (PaneSnapshot) resourceEntitySnapshot()               {}
func (TabSnapshot) resourceEntitySnapshot()                {}
func (TerminalSnapshot) resourceEntitySnapshot()           {}
func (BrowserSnapshot) resourceEntitySnapshot()            {}
func (ConnectedClientSnapshot) resourceEntitySnapshot()    {}
func (NotificationSnapshot) resourceEntitySnapshot()       {}
func (AgentSnapshot) resourceEntitySnapshot()              {}
func (PairingRequestSnapshot) resourceEntitySnapshot()     {}
func (FrontendProjectionSnapshot) resourceEntitySnapshot() {}
func (SidebarViewSnapshot) resourceEntitySnapshot()        {}

// ResourceChange preserves unknown future discriminators only in Raw. For
// known upsert/delete kinds, Resource, ID, and Value are validated together.
type ResourceChange struct {
	Kind     string
	Sequence uint32
	Resource ResourceKind
	ID       ResourceChangeID
	Value    ResourceEntitySnapshot
	Raw      Document
}

type Machine struct {
	client   *Client
	selector Selector[MachineID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *MachineSnapshot
}

type Session struct {
	client   *Client
	machine  Selector[MachineID]
	selector Selector[SessionID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *SessionSnapshot
}

type Workspace struct {
	client   *Client
	session  Selector[SessionID]
	selector Selector[WorkspaceID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *WorkspaceSnapshot
}

type Screen struct {
	client    *Client
	workspace Selector[WorkspaceID]
	selector  Selector[ScreenID]
	route     resourceRoute
	mu        sync.RWMutex
	snapshot  *ScreenSnapshot
}

type Pane struct {
	client   *Client
	screen   Selector[ScreenID]
	selector Selector[PaneID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *PaneSnapshot
}

type Tab struct {
	client   *Client
	pane     Selector[PaneID]
	selector Selector[TabID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *TabSnapshot
}

type Terminal struct {
	client   *Client
	tab      Selector[TabID]
	selector Selector[TerminalID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *TerminalSnapshot
}

type Browser struct {
	client   *Client
	tab      Selector[TabID]
	selector Selector[BrowserID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *BrowserSnapshot
}

type ConnectedClient struct {
	client   *Client
	session  Selector[SessionID]
	selector Selector[ConnectedClientID]
	route    resourceRoute
}

type Notification struct {
	client   *Client
	session  Selector[SessionID]
	route    resourceRoute
	snapshot NotificationSnapshot
}

type Agent struct {
	client   *Client
	session  Selector[SessionID]
	route    resourceRoute
	snapshot AgentSnapshot
}

type PairingRequest struct {
	client   *Client
	session  Selector[SessionID]
	route    resourceRoute
	snapshot PairingRequestSnapshot
}

type FrontendProjection struct {
	client   *Client
	session  Selector[SessionID]
	route    resourceRoute
	snapshot FrontendProjectionSnapshot
}

type SidebarView struct {
	client   *Client
	session  Selector[SessionID]
	selector Selector[SidebarViewID]
	route    resourceRoute
	mu       sync.RWMutex
	snapshot *SidebarViewSnapshot
}

func (c *Client) Machine(selector Selector[MachineID]) *Machine {
	route := resourceRoute{}.withMachine(selector)
	return &Machine{client: c, selector: selector, route: route}
}
func (c *Client) Session(selector Selector[SessionID]) *Session {
	machine := SelectCurrent[MachineID]()
	return &Session{
		client: c, machine: machine, selector: selector,
		route: resourceRoute{}.withMachine(machine).withSession(selector),
	}
}
func (m *Machine) Session(selector Selector[SessionID]) *Session {
	route := m.route.withSession(selector)
	return &Session{
		client: m.client, machine: m.selector, selector: selector, route: route,
	}
}
func (s *Session) Workspace(selector Selector[WorkspaceID]) *Workspace {
	return &Workspace{
		client: s.client, session: s.selector, selector: selector,
		route: s.route.withWorkspace(selector),
	}
}
func (s *Session) Terminal(selector Selector[TerminalID]) *Terminal {
	return &Terminal{
		client: s.client, selector: selector,
		route: s.route.withTerminal(selector),
	}
}
func (s *Session) Browser(selector Selector[BrowserID]) *Browser {
	return &Browser{
		client: s.client, selector: selector,
		route: s.route.withBrowser(selector),
	}
}
func (w *Workspace) Screen(selector Selector[ScreenID]) *Screen {
	return &Screen{
		client: w.client, workspace: w.selector, selector: selector,
		route: w.route.withScreen(selector),
	}
}
func (s *Screen) Pane(selector Selector[PaneID]) *Pane {
	return &Pane{
		client: s.client, screen: s.selector, selector: selector,
		route: s.route.withPane(selector),
	}
}
func (p *Pane) Tab(selector Selector[TabID]) *Tab {
	return &Tab{
		client: p.client, pane: p.selector, selector: selector,
		route: p.route.withTab(selector),
	}
}
func (t *Tab) Terminal(selector Selector[TerminalID]) *Terminal {
	return &Terminal{
		client: t.client, tab: t.selector, selector: selector,
		route: t.route.withTerminal(selector),
	}
}
func (t *Tab) Browser(selector Selector[BrowserID]) *Browser {
	return &Browser{
		client: t.client, tab: t.selector, selector: selector,
		route: t.route.withBrowser(selector),
	}
}
func (s *Session) ConnectedClient(selector Selector[ConnectedClientID]) *ConnectedClient {
	return &ConnectedClient{
		client: s.client, session: s.selector, selector: selector,
		route: s.route.withConnectedClient(selector),
	}
}
func (s *Session) FrontendProjection(
	selector Selector[ProjectionID],
) *FrontendProjection {
	return &FrontendProjection{
		client: s.client, session: s.selector,
		route: s.route.withProjection(selector),
	}
}
func (s *Session) SidebarView(selector Selector[SidebarViewID]) *SidebarView {
	return &SidebarView{
		client: s.client, session: s.selector, selector: selector,
		route: s.route.withSidebarView(selector),
	}
}

type resourceRoute struct {
	machine         Selector[MachineID]
	session         Selector[SessionID]
	workspace       Selector[WorkspaceID]
	screen          Selector[ScreenID]
	pane            Selector[PaneID]
	tab             Selector[TabID]
	terminal        Selector[TerminalID]
	browser         Selector[BrowserID]
	connectedClient Selector[ConnectedClientID]
	pairingRequest  Selector[PairingRequestID]
	projection      Selector[ProjectionID]
	sidebarView     Selector[SidebarViewID]
}

func (r resourceRoute) withMachine(value Selector[MachineID]) resourceRoute {
	r.machine = value
	return r
}
func (r resourceRoute) withSession(value Selector[SessionID]) resourceRoute {
	r.session = value
	return r
}
func (r resourceRoute) withWorkspace(value Selector[WorkspaceID]) resourceRoute {
	r.workspace = value
	return r
}
func (r resourceRoute) withScreen(value Selector[ScreenID]) resourceRoute {
	r.screen = value
	return r
}
func (r resourceRoute) withPane(value Selector[PaneID]) resourceRoute {
	r.pane = value
	return r
}
func (r resourceRoute) withTab(value Selector[TabID]) resourceRoute {
	r.tab = value
	return r
}
func (r resourceRoute) withTerminal(value Selector[TerminalID]) resourceRoute {
	r.terminal = value
	return r
}
func (r resourceRoute) withBrowser(value Selector[BrowserID]) resourceRoute {
	r.browser = value
	return r
}
func (r resourceRoute) withConnectedClient(
	value Selector[ConnectedClientID],
) resourceRoute {
	r.connectedClient = value
	return r
}
func (r resourceRoute) withPairingRequest(
	value Selector[PairingRequestID],
) resourceRoute {
	r.pairingRequest = value
	return r
}
func (r resourceRoute) withProjection(
	value Selector[ProjectionID],
) resourceRoute {
	r.projection = value
	return r
}
func (r resourceRoute) withSidebarView(value Selector[SidebarViewID]) resourceRoute {
	r.sidebarView = value
	return r
}
func (r resourceRoute) params() map[string]any {
	result := make(map[string]any, 12)
	addSelector(result, wirev2.FieldMachine, r.machine)
	addSelector(result, wirev2.FieldSession, r.session)
	addSelector(result, wirev2.FieldWorkspace, r.workspace)
	addSelector(result, wirev2.FieldScreen, r.screen)
	addSelector(result, wirev2.FieldPane, r.pane)
	addSelector(result, wirev2.FieldTab, r.tab)
	addSelector(result, wirev2.FieldTerminal, r.terminal)
	addSelector(result, wirev2.FieldBrowser, r.browser)
	addSelector(result, wirev2.FieldClient, r.connectedClient)
	addSelector(result, "pairing_request", r.pairingRequest)
	addSelector(result, "frontend_projection", r.projection)
	addSelector(result, "sidebar_view", r.sidebarView)
	return result
}

func (m *Machine) Cached() (MachineSnapshot, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.snapshot == nil {
		return MachineSnapshot{}, false
	}
	return *m.snapshot, true
}
func (s *Session) Cached() (SessionSnapshot, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.snapshot == nil {
		return SessionSnapshot{}, false
	}
	return *s.snapshot, true
}
func (w *Workspace) Cached() (WorkspaceSnapshot, bool) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.snapshot == nil {
		return WorkspaceSnapshot{}, false
	}
	return *w.snapshot, true
}
func (s *Screen) Cached() (ScreenSnapshot, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.snapshot == nil {
		return ScreenSnapshot{}, false
	}
	return *s.snapshot, true
}
func (p *Pane) Cached() (PaneSnapshot, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.snapshot == nil {
		return PaneSnapshot{}, false
	}
	return *p.snapshot, true
}
func (t *Tab) Cached() (TabSnapshot, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	if t.snapshot == nil {
		return TabSnapshot{}, false
	}
	return *t.snapshot, true
}
func (t *Terminal) Cached() (TerminalSnapshot, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	if t.snapshot == nil {
		return TerminalSnapshot{}, false
	}
	return *t.snapshot, true
}
func (b *Browser) Cached() (BrowserSnapshot, bool) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.snapshot == nil {
		return BrowserSnapshot{}, false
	}
	return *b.snapshot, true
}
func (s *SidebarView) Cached() (SidebarViewSnapshot, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.snapshot == nil {
		return SidebarViewSnapshot{}, false
	}
	return *s.snapshot, true
}

func cacheSnapshot[ID opaqueID, Value any](
	mu *sync.RWMutex,
	cached **Value,
	selector Selector[ID],
	value Value,
	id func(Value) ID,
	label string,
) error {
	mu.Lock()
	defer mu.Unlock()
	actualID := id(value)
	if expectedID, ok := selector.ID(); ok && expectedID != actualID {
		return &ProtocolError{
			Message: fmt.Sprintf(
				"%s mutation returned %s for %s",
				label,
				actualID,
				expectedID,
			),
		}
	}
	if *cached != nil {
		cachedID := id(**cached)
		if cachedID != actualID {
			return &ProtocolError{
				Message: fmt.Sprintf(
					"%s mutation changed handle identity from %s to %s",
					label,
					cachedID,
					actualID,
				),
			}
		}
	}
	copy := value
	*cached = &copy
	return nil
}

func (m *Machine) cache(value MachineSnapshot) error {
	return cacheSnapshot(
		&m.mu, &m.snapshot, m.selector, value,
		func(value MachineSnapshot) MachineID { return value.ID },
		"machine",
	)
}

func (w *Workspace) cache(value WorkspaceSnapshot) error {
	return cacheSnapshot(
		&w.mu, &w.snapshot, w.selector, value,
		func(value WorkspaceSnapshot) WorkspaceID { return value.ID },
		"workspace",
	)
}

func (s *Screen) cache(value ScreenSnapshot) error {
	return cacheSnapshot(
		&s.mu, &s.snapshot, s.selector, value,
		func(value ScreenSnapshot) ScreenID { return value.ID },
		"screen",
	)
}

func (p *Pane) cache(value PaneSnapshot) error {
	return cacheSnapshot(
		&p.mu, &p.snapshot, p.selector, value,
		func(value PaneSnapshot) PaneID { return value.ID },
		"pane",
	)
}

func (t *Tab) cache(value TabSnapshot) error {
	return cacheSnapshot(
		&t.mu, &t.snapshot, t.selector, value,
		func(value TabSnapshot) TabID { return value.ID },
		"tab",
	)
}

func (t *Terminal) cache(value TerminalSnapshot) error {
	return cacheSnapshot(
		&t.mu, &t.snapshot, t.selector, value,
		func(value TerminalSnapshot) TerminalID { return value.ID },
		"terminal",
	)
}

func (b *Browser) cache(value BrowserSnapshot) error {
	return cacheSnapshot(
		&b.mu, &b.snapshot, b.selector, value,
		func(value BrowserSnapshot) BrowserID { return value.ID },
		"browser",
	)
}

func (s *SidebarView) cache(value SidebarViewSnapshot) error {
	return cacheSnapshot(
		&s.mu, &s.snapshot, s.selector, value,
		func(value SidebarViewSnapshot) SidebarViewID { return value.ID },
		"sidebar view",
	)
}

func (p *PairingRequest) cache(value PairingResolutionResult) error {
	if value.PairingRequest.ID != p.snapshot.ID {
		return &ProtocolError{
			Message: fmt.Sprintf(
				"pairing request mutation returned %s for %s",
				value.PairingRequest.ID,
				p.snapshot.ID,
			),
		}
	}
	p.snapshot = value.PairingRequest
	return nil
}

func (p *FrontendProjection) cache(value FrontendProjectionSnapshot) error {
	if value.ID != p.snapshot.ID {
		return &ProtocolError{
			Message: fmt.Sprintf(
				"frontend projection mutation returned %s for %s",
				value.ID,
				p.snapshot.ID,
			),
		}
	}
	p.snapshot = value
	return nil
}

func (m *Machine) Refresh(ctx context.Context) (MachineSnapshot, error) {
	var snapshot MachineSnapshot
	if err := m.client.readResource(ctx, wirev2.MachineGet, m.route.params(), &snapshot); err != nil {
		return MachineSnapshot{}, err
	}
	m.mu.Lock()
	m.snapshot = &snapshot
	m.mu.Unlock()
	return snapshot, nil
}
func (s *Session) Refresh(ctx context.Context) (SessionSnapshot, error) {
	var snapshot SessionSnapshot
	if err := s.client.readResource(ctx, wirev2.SessionGet, s.route.params(), &snapshot); err != nil {
		return SessionSnapshot{}, err
	}
	s.mu.Lock()
	s.snapshot = &snapshot
	s.mu.Unlock()
	return snapshot, nil
}
func (w *Workspace) Refresh(ctx context.Context) (WorkspaceSnapshot, error) {
	var snapshot WorkspaceSnapshot
	if err := w.client.readResource(ctx, wirev2.WorkspaceGet, w.route.params(), &snapshot); err != nil {
		return WorkspaceSnapshot{}, err
	}
	w.mu.Lock()
	w.snapshot = &snapshot
	w.mu.Unlock()
	return snapshot, nil
}
func (s *Screen) Refresh(ctx context.Context) (ScreenSnapshot, error) {
	var snapshot ScreenSnapshot
	if err := s.client.readResource(ctx, wirev2.ScreenGet, s.route.params(), &snapshot); err != nil {
		return ScreenSnapshot{}, err
	}
	s.mu.Lock()
	s.snapshot = &snapshot
	s.mu.Unlock()
	return snapshot, nil
}
func (p *Pane) Refresh(ctx context.Context) (PaneSnapshot, error) {
	var snapshot PaneSnapshot
	if err := p.client.readResource(ctx, wirev2.PaneGet, p.route.params(), &snapshot); err != nil {
		return PaneSnapshot{}, err
	}
	p.mu.Lock()
	p.snapshot = &snapshot
	p.mu.Unlock()
	return snapshot, nil
}
func (t *Tab) Refresh(ctx context.Context) (TabSnapshot, error) {
	var snapshot TabSnapshot
	if err := t.client.readResource(ctx, wirev2.TabGet, t.route.params(), &snapshot); err != nil {
		return TabSnapshot{}, err
	}
	t.mu.Lock()
	t.snapshot = &snapshot
	t.mu.Unlock()
	return snapshot, nil
}
func (t *Terminal) Refresh(ctx context.Context) (TerminalSnapshot, error) {
	var snapshot TerminalSnapshot
	if err := t.client.readResource(ctx, wirev2.TerminalGet, t.route.params(), &snapshot); err != nil {
		return TerminalSnapshot{}, err
	}
	t.mu.Lock()
	t.snapshot = &snapshot
	t.mu.Unlock()
	return snapshot, nil
}
func (b *Browser) Refresh(ctx context.Context) (BrowserSnapshot, error) {
	var snapshot BrowserSnapshot
	if err := b.client.readResource(ctx, wirev2.BrowserGet, b.route.params(), &snapshot); err != nil {
		return BrowserSnapshot{}, err
	}
	b.mu.Lock()
	b.snapshot = &snapshot
	b.mu.Unlock()
	return snapshot, nil
}

func (c *Client) readResource(ctx context.Context, operation wirev2.Operation, params map[string]any, target any) error {
	var raw json.RawMessage
	if err := c.do(ctx, operation, params, "", &raw); err != nil {
		return err
	}
	return decodeResource(raw, target)
}

func addSelector[T opaqueID](params map[string]any, field string, selector Selector[T]) {
	if selector.valid {
		params[field] = selector.String()
	}
}

func decodeResource(raw json.RawMessage, target any) error {
	if err := strictDecode(raw, target); err != nil {
		return &ProtocolError{Message: "cannot decode resource snapshot: " + err.Error()}
	}
	if err := validateRequiredJSON(
		raw,
		reflect.TypeOf(target),
		"resource snapshot",
	); err != nil {
		return &ProtocolError{Message: "cannot decode resource snapshot: " + err.Error()}
	}
	if err := validateDecodedValue(raw, target); err != nil {
		return &ProtocolError{Message: "cannot decode resource snapshot: " + err.Error()}
	}
	return nil
}

func decodeList[T any](raw json.RawMessage, field string) ([]T, error) {
	var items []json.RawMessage
	if err := strictDecode(raw, &items); err != nil {
		return nil, &ProtocolError{
			Message: fmt.Sprintf("cannot decode %s list: %s", field, err),
		}
	}
	if items == nil {
		return nil, &ProtocolError{
			Message: fmt.Sprintf("%s list must be an array", field),
		}
	}
	list := make([]T, 0, len(items))
	for index, item := range items {
		value, err := decodeValue[T](item, field+" item")
		if err != nil {
			return nil, &ProtocolError{
				Message: fmt.Sprintf(
					"cannot decode %s item %d: %s",
					field,
					index,
					err,
				),
			}
		}
		list = append(list, value)
	}
	return list, nil
}

func strictDecode(raw json.RawMessage, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("trailing JSON value")
		}
		return err
	}
	return nil
}

func validateRequiredJSON(
	raw json.RawMessage,
	valueType reflect.Type,
	path string,
) error {
	for valueType.Kind() == reflect.Pointer {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return nil
		}
		valueType = valueType.Elem()
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) &&
		valueType.Kind() == reflect.Interface {
		return nil
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return fmt.Errorf("%s must not be null", path)
	}
	jsonUnmarshaler := reflect.TypeOf((*json.Unmarshaler)(nil)).Elem()
	if valueType.Implements(jsonUnmarshaler) ||
		reflect.PointerTo(valueType).Implements(jsonUnmarshaler) {
		return nil
	}
	switch valueType.Kind() {
	case reflect.Struct:
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			return err
		}
		if fields == nil {
			return fmt.Errorf("%s must be an object", path)
		}
		for index := 0; index < valueType.NumField(); index++ {
			field := valueType.Field(index)
			if !field.IsExported() {
				continue
			}
			tag := field.Tag.Get("json")
			parts := strings.Split(tag, ",")
			name := parts[0]
			if name == "-" {
				continue
			}
			if name == "" {
				name = field.Name
			}
			optional := false
			for _, option := range parts[1:] {
				if option == "omitempty" || option == "omitzero" {
					optional = true
				}
			}
			fieldRaw, present := fields[name]
			if !present {
				if optional {
					continue
				}
				return fmt.Errorf("%s omitted required field %s", path, name)
			}
			if err := validateRequiredJSON(
				fieldRaw,
				field.Type,
				path+"."+name,
			); err != nil {
				return err
			}
		}
	case reflect.Slice, reflect.Array:
		if valueType == reflect.TypeOf(json.RawMessage{}) ||
			valueType == reflect.TypeOf([]byte{}) {
			return nil
		}
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return err
		}
		if items == nil {
			return fmt.Errorf("%s must be an array", path)
		}
		for index, item := range items {
			if err := validateRequiredJSON(
				item,
				valueType.Elem(),
				fmt.Sprintf("%s[%d]", path, index),
			); err != nil {
				return err
			}
		}
	}
	return nil
}
