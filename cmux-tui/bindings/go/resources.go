package cmux

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev1"
)

type MachineSnapshot struct {
	ID              MachineID        `json:"id"`
	Name            string           `json:"name"`
	Origin          string           `json:"origin"`
	Status          string           `json:"status"`
	Connectable     bool             `json:"connectable"`
	ProviderScopeID *ProviderScopeID `json:"provider_scope_id,omitempty"`
	Deleted         bool             `json:"deleted"`
	Recoverable     bool             `json:"recoverable"`
	Extra           map[string]any   `json:"extra,omitempty"`
}

type SessionSnapshot struct {
	ID         SessionID      `json:"id"`
	MachineID  MachineID      `json:"machine_id"`
	Name       *string        `json:"name,omitempty"`
	Generation string         `json:"generation"`
	Revision   Decimal        `json:"revision"`
	Connected  bool           `json:"connected"`
	Extra      map[string]any `json:"extra,omitempty"`
}

type WorkspaceSnapshot struct {
	ID        WorkspaceID    `json:"id"`
	SessionID SessionID      `json:"session_id"`
	Name      string         `json:"name"`
	Index     uint32         `json:"index"`
	Focused   bool           `json:"focused"`
	Extra     map[string]any `json:"extra,omitempty"`
}

type LayoutDocument map[string]any

type ScreenSnapshot struct {
	ID          ScreenID       `json:"id"`
	WorkspaceID WorkspaceID    `json:"workspace_id"`
	Name        *string        `json:"name"`
	Index       uint32         `json:"index"`
	Focused     bool           `json:"focused"`
	Layout      LayoutDocument `json:"layout"`
	Extra       map[string]any `json:"extra,omitempty"`
}

type PaneSnapshot struct {
	ID       PaneID         `json:"id"`
	ScreenID ScreenID       `json:"screen_id"`
	Name     *string        `json:"name"`
	Focused  bool           `json:"focused"`
	Zoomed   bool           `json:"zoomed"`
	Extra    map[string]any `json:"extra,omitempty"`
}

type TabSnapshot struct {
	ID          TabID          `json:"id"`
	PaneID      PaneID         `json:"pane_id"`
	Name        *string        `json:"name"`
	Index       uint32         `json:"index"`
	Focused     bool           `json:"focused"`
	ContentKind string         `json:"content_kind"`
	ContentID   TabContentID   `json:"-"`
	Extra       map[string]any `json:"extra,omitempty"`
}

func (s *TabSnapshot) UnmarshalJSON(data []byte) error {
	var wire struct {
		ID          TabID           `json:"id"`
		PaneID      PaneID          `json:"pane_id"`
		Name        json.RawMessage `json:"name"`
		Index       uint32          `json:"index"`
		Focused     bool            `json:"focused"`
		ContentKind string          `json:"content_kind"`
		ContentID   string          `json:"content_id"`
		Extra       map[string]any  `json:"extra,omitempty"`
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
		ID          TabID          `json:"id"`
		PaneID      PaneID         `json:"pane_id"`
		Name        *string        `json:"name"`
		Index       uint32         `json:"index"`
		Focused     bool           `json:"focused"`
		ContentKind string         `json:"content_kind"`
		ContentID   string         `json:"content_id"`
		Extra       map[string]any `json:"extra,omitempty"`
	}{
		ID: s.ID, PaneID: s.PaneID, Name: s.Name, Index: s.Index,
		Focused: s.Focused, ContentKind: s.ContentKind,
		ContentID: s.ContentID.String(), Extra: s.Extra,
	})
}

type TerminalSnapshot struct {
	ID      TerminalID     `json:"id"`
	TabID   TabID          `json:"tab_id"`
	Title   string         `json:"title"`
	CWD     *string        `json:"cwd,omitempty"`
	Cols    uint16         `json:"cols"`
	Rows    uint16         `json:"rows"`
	Running bool           `json:"running"`
	Extra   map[string]any `json:"extra,omitempty"`
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
	ID            BrowserID      `json:"id"`
	TabID         TabID          `json:"tab_id"`
	URL           string         `json:"url"`
	Title         string         `json:"title"`
	Loading       bool           `json:"loading"`
	Source        string         `json:"source"`
	Status        string         `json:"status"`
	Error         *string        `json:"error"`
	FramesStalled bool           `json:"frames_stalled"`
	Size          Size           `json:"size"`
	Extra         map[string]any `json:"extra,omitempty"`
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
	Extra               map[string]any       `json:"extra,omitempty"`
}

type ClientTerminalSize struct {
	TerminalID    TerminalID `json:"terminal_id"`
	Cols          *uint16    `json:"cols"`
	Rows          *uint16    `json:"rows"`
	Participating bool       `json:"participating"`
}

type NotificationSnapshot struct {
	ID          NotificationID `json:"id"`
	SessionID   SessionID      `json:"session_id"`
	Title       string         `json:"title"`
	Body        string         `json:"body"`
	Level       string         `json:"level"`
	TerminalID  *TerminalID    `json:"terminal_id,omitempty"`
	CreatedAtMS Decimal        `json:"created_at_ms"`
	Unread      bool           `json:"unread"`
	Extra       map[string]any `json:"extra,omitempty"`
}

type AgentSnapshot struct {
	ID            AgentID        `json:"id"`
	SessionID     SessionID      `json:"session_id"`
	TerminalID    TerminalID     `json:"terminal_id"`
	State         string         `json:"state"`
	Source        string         `json:"source"`
	UpdatedAtMS   Decimal        `json:"updated_at_ms"`
	SourceSession *string        `json:"source_session"`
	Extra         map[string]any `json:"extra,omitempty"`
}

type PairingRequestSnapshot struct {
	ID               PairingRequestID `json:"id"`
	SessionID        SessionID        `json:"session_id"`
	Peer             string           `json:"peer"`
	Code             Secret           `json:"code"`
	ExpiresInSeconds Decimal          `json:"expires_in_seconds"`
	Status           string           `json:"status"`
	Extra            map[string]any   `json:"extra,omitempty"`
}

type FrontendProjectionSnapshot struct {
	ID         ProjectionID   `json:"id"`
	SessionID  SessionID      `json:"session_id"`
	Projection any            `json:"projection"`
	Extra      map[string]any `json:"extra,omitempty"`
}

type SidebarViewSnapshot struct {
	ID        SidebarViewID  `json:"id"`
	SessionID SessionID      `json:"session_id"`
	Cols      uint16         `json:"cols"`
	Rows      uint16         `json:"rows"`
	Running   bool           `json:"running"`
	Extra     map[string]any `json:"extra,omitempty"`
}

type ProviderScopeSnapshot struct {
	ID       ProviderScopeID `json:"id"`
	Name     string          `json:"name"`
	Kind     string          `json:"kind"`
	CanAdmin bool            `json:"can_admin"`
	Selected bool            `json:"selected"`
	Extra    map[string]any  `json:"extra,omitempty"`
}

type ProviderActionSnapshot struct {
	ID              ProviderActionID      `json:"id"`
	ProviderScopeID ProviderScopeID       `json:"provider_scope_id"`
	Name            string                `json:"name"`
	Title           string                `json:"title"`
	Enabled         bool                  `json:"enabled"`
	Target          string                `json:"target"`
	Destructive     bool                  `json:"destructive"`
	Fields          []ProviderActionField `json:"fields"`
	Extra           map[string]any        `json:"extra,omitempty"`
}

type ProviderActionField struct {
	ID          string  `json:"id"`
	Label       string  `json:"label"`
	Kind        string  `json:"kind"`
	Required    bool    `json:"required"`
	MaxLength   *uint32 `json:"max_length,omitempty"`
	Minimum     *int32  `json:"minimum,omitempty"`
	Maximum     *int32  `json:"maximum,omitempty"`
	Placeholder *string `json:"placeholder,omitempty"`
}

type ProviderNoticeSnapshot struct {
	ID              ProviderNoticeID `json:"id"`
	ProviderScopeID ProviderScopeID  `json:"provider_scope_id"`
	Level           string           `json:"level"`
	Message         string           `json:"message"`
	Extra           map[string]any   `json:"extra,omitempty"`
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
}

type ProviderScope struct {
	client   *Client
	selector Selector[ProviderScopeID]
	route    resourceRoute
	snapshot ProviderScopeSnapshot
}

type ProviderAction struct {
	client   *Client
	scope    Selector[ProviderScopeID]
	selector Selector[ProviderActionID]
	route    resourceRoute
	snapshot ProviderActionSnapshot
}

type ProviderNotice struct {
	client   *Client
	selector Selector[ProviderNoticeID]
	route    resourceRoute
	snapshot ProviderNoticeSnapshot
}

func (c *Client) Machine(selector Selector[MachineID]) *Machine {
	route := resourceRoute{}.withMachine(selector)
	return &Machine{client: c, selector: selector, route: route}
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
func (c *Client) ProviderScope(selector Selector[ProviderScopeID]) *ProviderScope {
	route := resourceRoute{}.
		withMachine(SelectCurrent[MachineID]()).
		withProviderScope(selector)
	return &ProviderScope{client: c, selector: selector, route: route}
}
func (m *Machine) ProviderScope(selector Selector[ProviderScopeID]) *ProviderScope {
	return &ProviderScope{
		client: m.client, selector: selector,
		route: m.route.withProviderScope(selector),
	}
}
func (p *ProviderScope) Action(selector Selector[ProviderActionID]) *ProviderAction {
	return &ProviderAction{
		client: p.client, scope: p.selector, selector: selector,
		route: p.route.withProviderAction(selector),
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
	providerScope   Selector[ProviderScopeID]
	providerAction  Selector[ProviderActionID]
	providerNotice  Selector[ProviderNoticeID]
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
func (r resourceRoute) withProviderScope(
	value Selector[ProviderScopeID],
) resourceRoute {
	r.providerScope = value
	return r
}
func (r resourceRoute) withProviderAction(
	value Selector[ProviderActionID],
) resourceRoute {
	r.providerAction = value
	return r
}
func (r resourceRoute) withProviderNotice(
	value Selector[ProviderNoticeID],
) resourceRoute {
	r.providerNotice = value
	return r
}

func (r resourceRoute) params() map[string]any {
	result := make(map[string]any, 12)
	addSelector(result, wirev1.FieldMachine, r.machine)
	addSelector(result, wirev1.FieldSession, r.session)
	addSelector(result, wirev1.FieldWorkspace, r.workspace)
	addSelector(result, wirev1.FieldScreen, r.screen)
	addSelector(result, wirev1.FieldPane, r.pane)
	addSelector(result, wirev1.FieldTab, r.tab)
	addSelector(result, wirev1.FieldTerminal, r.terminal)
	addSelector(result, wirev1.FieldBrowser, r.browser)
	addSelector(result, wirev1.FieldClient, r.connectedClient)
	addSelector(result, "pairing_request", r.pairingRequest)
	addSelector(result, "frontend_projection", r.projection)
	addSelector(result, "sidebar_view", r.sidebarView)
	addSelector(result, "provider_scope", r.providerScope)
	addSelector(result, "provider_action", r.providerAction)
	addSelector(result, "provider_notice", r.providerNotice)
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

func (m *Machine) Refresh(ctx context.Context) (MachineSnapshot, error) {
	var snapshot MachineSnapshot
	if err := m.client.readResource(ctx, wirev1.MachineGet, m.route.params(), &snapshot); err != nil {
		return MachineSnapshot{}, err
	}
	m.mu.Lock()
	m.snapshot = &snapshot
	m.mu.Unlock()
	return snapshot, nil
}
func (s *Session) Refresh(ctx context.Context) (SessionSnapshot, error) {
	var snapshot SessionSnapshot
	if err := s.client.readResource(ctx, wirev1.SessionGet, s.route.params(), &snapshot); err != nil {
		return SessionSnapshot{}, err
	}
	s.mu.Lock()
	s.snapshot = &snapshot
	s.mu.Unlock()
	return snapshot, nil
}
func (w *Workspace) Refresh(ctx context.Context) (WorkspaceSnapshot, error) {
	var snapshot WorkspaceSnapshot
	if err := w.client.readResource(ctx, wirev1.WorkspaceGet, w.route.params(), &snapshot); err != nil {
		return WorkspaceSnapshot{}, err
	}
	w.mu.Lock()
	w.snapshot = &snapshot
	w.mu.Unlock()
	return snapshot, nil
}
func (s *Screen) Refresh(ctx context.Context) (ScreenSnapshot, error) {
	var snapshot ScreenSnapshot
	if err := s.client.readResource(ctx, wirev1.ScreenGet, s.route.params(), &snapshot); err != nil {
		return ScreenSnapshot{}, err
	}
	s.mu.Lock()
	s.snapshot = &snapshot
	s.mu.Unlock()
	return snapshot, nil
}
func (p *Pane) Refresh(ctx context.Context) (PaneSnapshot, error) {
	var snapshot PaneSnapshot
	if err := p.client.readResource(ctx, wirev1.PaneGet, p.route.params(), &snapshot); err != nil {
		return PaneSnapshot{}, err
	}
	p.mu.Lock()
	p.snapshot = &snapshot
	p.mu.Unlock()
	return snapshot, nil
}
func (t *Tab) Refresh(ctx context.Context) (TabSnapshot, error) {
	var snapshot TabSnapshot
	if err := t.client.readResource(ctx, wirev1.TabGet, t.route.params(), &snapshot); err != nil {
		return TabSnapshot{}, err
	}
	t.mu.Lock()
	t.snapshot = &snapshot
	t.mu.Unlock()
	return snapshot, nil
}
func (t *Terminal) Refresh(ctx context.Context) (TerminalSnapshot, error) {
	var snapshot TerminalSnapshot
	if err := t.client.readResource(ctx, wirev1.TerminalGet, t.route.params(), &snapshot); err != nil {
		return TerminalSnapshot{}, err
	}
	t.mu.Lock()
	t.snapshot = &snapshot
	t.mu.Unlock()
	return snapshot, nil
}
func (b *Browser) Refresh(ctx context.Context) (BrowserSnapshot, error) {
	var snapshot BrowserSnapshot
	if err := b.client.readResource(ctx, wirev1.BrowserGet, b.route.params(), &snapshot); err != nil {
		return BrowserSnapshot{}, err
	}
	b.mu.Lock()
	b.snapshot = &snapshot
	b.mu.Unlock()
	return snapshot, nil
}

func (c *Client) readResource(ctx context.Context, operation wirev1.Operation, params map[string]any, target any) error {
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
	return nil
}

func decodeList[T any](raw json.RawMessage, field string) ([]T, error) {
	var list []T
	if err := strictDecode(raw, &list); err != nil {
		return nil, &ProtocolError{
			Message: fmt.Sprintf("cannot decode %s list: %s", field, err),
		}
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
