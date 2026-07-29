package cmux

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev1"
)

func params(extra map[string]any) map[string]any {
	result := make(map[string]any, len(extra)+4)
	for key, value := range extra {
		result[key] = value
	}
	return result
}

func putString(target map[string]any, key, value string) {
	if value != "" {
		target[key] = value
	}
}

func putOptionalString(target map[string]any, key string, value *string) {
	if value != nil {
		target[key] = *value
	}
}

func (c *Client) readDocument(ctx context.Context, operation wirev1.Operation, input map[string]any) (Document, error) {
	var fields map[string]any
	if err := c.do(ctx, operation, input, "", &fields); err != nil {
		return Document{}, err
	}
	return Document{Fields: fields}, nil
}

func mutationValue[T any](
	ctx context.Context,
	client *Client,
	operation wirev1.Operation,
	input map[string]any,
	options MutationOptions,
	label string,
) (MutationResult[T], error) {
	putExpectedRevision(input, options)
	raw, err := client.mutationRaw(ctx, operation, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[T]{}, err
	}
	value, err := decodeValue[T](raw.value, label)
	if err != nil {
		return MutationResult[T]{}, err
	}
	return MutationResult[T]{
		Value: value, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}

func (c *Client) controlDocument(ctx context.Context, operation wirev1.Operation, input map[string]any) (Document, error) {
	return c.readDocument(ctx, operation, input)
}

type mutationWireResult struct {
	value      json.RawMessage
	generation string
	revision   Decimal
	replayed   bool
}

func (c *Client) mutationRaw(
	ctx context.Context,
	operation wirev1.Operation,
	input map[string]any,
	idempotencyKey string,
) (mutationWireResult, error) {
	var fields map[string]json.RawMessage
	if err := c.do(ctx, operation, input, idempotencyKey, &fields); err != nil {
		return mutationWireResult{}, err
	}
	for key := range fields {
		switch key {
		case "value", wirev1.FieldGeneration, wirev1.FieldRevision, "replayed":
		default:
			return mutationWireResult{}, &ProtocolError{
				Message: operation.Name + " mutation result has unknown field " + key,
			}
		}
	}
	value, ok := fields["value"]
	if !ok {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation result omitted value",
		}
	}
	generationRaw, ok := fields[wirev1.FieldGeneration]
	if !ok {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation result omitted generation",
		}
	}
	var generation string
	if err := json.Unmarshal(generationRaw, &generation); err != nil || generation == "" {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation generation must be a non-empty string",
		}
	}
	revisionRaw, ok := fields[wirev1.FieldRevision]
	if !ok {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation result omitted revision",
		}
	}
	var revision Decimal
	if err := json.Unmarshal(revisionRaw, &revision); err != nil {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation revision is invalid: " + err.Error(),
		}
	}
	replayedRaw, ok := fields["replayed"]
	if !ok {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation result omitted replayed",
		}
	}
	var replayed bool
	if err := json.Unmarshal(replayedRaw, &replayed); err != nil {
		return mutationWireResult{}, &ProtocolError{
			Message: operation.Name + " mutation replayed must be boolean",
		}
	}
	return mutationWireResult{
		value: value, generation: generation, revision: revision, replayed: replayed,
	}, nil
}

func (c *Client) created(
	ctx context.Context,
	operation wirev1.Operation,
	input map[string]any,
	options MutationOptions,
) (MutationResult[CreatedPath], error) {
	putExpectedRevision(input, options)
	raw, err := c.mutationRaw(ctx, operation, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[CreatedPath]{}, err
	}
	var path CreatedPath
	if err := json.Unmarshal(raw.value, &path); err != nil {
		return MutationResult[CreatedPath]{}, &ProtocolError{Message: "cannot decode created path: " + err.Error()}
	}
	return MutationResult[CreatedPath]{
		Value:      path,
		Generation: raw.generation,
		Revision:   raw.revision,
		Replayed:   raw.replayed,
	}, nil
}

func putExpectedRevision(input map[string]any, options MutationOptions) {
	if options.ExpectedRevision != nil {
		input["expected_revision"] = *options.ExpectedRevision
	}
}

func (c *Client) ListMachines(ctx context.Context, options MachineListOptions) ([]*Machine, error) {
	var raw json.RawMessage
	if err := c.do(ctx, wirev1.MachineList, params(options.Extra), "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[MachineSnapshot](raw, "machines")
	if err != nil {
		return nil, err
	}
	result := make([]*Machine, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Machine{
			client: c, selector: selector,
			route:    resourceRoute{}.withMachine(selector),
			snapshot: snapshot,
		})
	}
	return result, nil
}

func (c *Client) FindMachinesByName(ctx context.Context, name string) ([]*Machine, error) {
	machines, err := c.ListMachines(ctx, MachineListOptions{})
	if err != nil {
		return nil, err
	}
	return filterMachines(machines, name), nil
}

func filterMachines(values []*Machine, name string) []*Machine {
	result := make([]*Machine, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && snapshot.Name == name {
			result = append(result, value)
		}
	}
	return result
}

func (c *Client) CreateMachine(ctx context.Context, options MachineCreateOptions) (MutationResult[*Machine], error) {
	return c.ProviderScope(SelectCurrent[ProviderScopeID]()).CreateMachine(ctx, options)
}

func (p *ProviderScope) CreateMachine(ctx context.Context, options MachineCreateOptions) (MutationResult[*Machine], error) {
	input := map[string]any{"provider_scope": p.selector.String()}
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := p.client.mutationRaw(ctx, wirev1.MachineCreate, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[*Machine]{}, err
	}
	snapshot, err := decodeValue[MachineSnapshot](raw.value, "machine")
	if err != nil {
		return MutationResult[*Machine]{}, err
	}
	selector := SelectID(snapshot.ID)
	handle := &Machine{
		client: p.client, selector: selector,
		route:    resourceRoute{}.withMachine(selector),
		snapshot: &snapshot,
	}
	return MutationResult[*Machine]{
		Value: handle, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}

func (p *ProviderScope) ConnectExternal(ctx context.Context, options MachineConnectExternalOptions) (MutationResult[*Machine], error) {
	input := map[string]any{"provider_scope": p.selector.String()}
	input["specifier"] = options.Specifier.Reveal()
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := p.client.mutationRaw(
		ctx, wirev1.MachineConnectExternal, input, options.IdempotencyKey,
	)
	if err != nil {
		return MutationResult[*Machine]{}, err
	}
	snapshot, err := decodeValue[MachineSnapshot](raw.value, "machine")
	if err != nil {
		return MutationResult[*Machine]{}, err
	}
	selector := SelectID(snapshot.ID)
	handle := &Machine{
		client: p.client, selector: selector,
		route: resourceRoute{}.withMachine(selector), snapshot: &snapshot,
	}
	return MutationResult[*Machine]{
		Value: handle, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}

func (c *Client) ConnectExternalMachine(
	ctx context.Context,
	options MachineConnectExternalOptions,
) (MutationResult[*Machine], error) {
	return c.ProviderScope(SelectCurrent[ProviderScopeID]()).
		ConnectExternal(ctx, options)
}

func (m *Machine) Rename(ctx context.Context, options MachineRenameOptions) (MutationResult[MachineSnapshot], error) {
	input := m.route.params()
	input[wirev1.FieldName] = options.Name
	if options.ConfirmClose {
		input["confirm_close"] = true
	}
	merge(input, options.Extra)
	result, err := mutationValue[MachineSnapshot](
		ctx, m.client, wirev1.MachineRename, input, options.MutationOptions, "machine",
	)
	if err == nil {
		m.mu.Lock()
		m.snapshot = &result.Value
		m.mu.Unlock()
	}
	return result, err
}
func (m *Machine) Delete(ctx context.Context, options MachineDeleteOptions) (MutationResult[MachineSnapshot], error) {
	input := m.route.params()
	merge(input, options.Extra)
	return mutationValue[MachineSnapshot](
		ctx, m.client, wirev1.MachineDelete, input, options.MutationOptions, "machine",
	)
}
func (m *Machine) Restore(ctx context.Context, options MachineRestoreOptions) (MutationResult[MachineSnapshot], error) {
	input := m.route.params()
	merge(input, options.Extra)
	return mutationValue[MachineSnapshot](
		ctx, m.client, wirev1.MachineRestore, input, options.MutationOptions, "machine",
	)
}
func (m *Machine) Purge(ctx context.Context, options MachinePurgeOptions) (MutationResult[EmptyResult], error) {
	input := m.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, m.client, wirev1.MachinePurge, input, options.MutationOptions, "empty result",
	)
}

func (m *Machine) ListSessions(ctx context.Context, options SessionListOptions) ([]*Session, error) {
	input := m.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := m.client.do(ctx, wirev1.SessionList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[SessionSnapshot](raw, "sessions")
	if err != nil {
		return nil, err
	}
	result := make([]*Session, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Session{
			client: m.client, machine: m.selector, selector: selector,
			route: m.route.withSession(selector), snapshot: snapshot,
		})
	}
	return result, nil
}

func (m *Machine) FindSessionsByName(ctx context.Context, name string) ([]*Session, error) {
	values, err := m.ListSessions(ctx, SessionListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Session, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && optionalNameMatches(snapshot.Name, name) {
			result = append(result, value)
		}
	}
	return result, nil
}

func (m *Machine) OpenSession(ctx context.Context, options SessionOpenOptions) (MutationResult[*Session], error) {
	input := m.route.withSession(options.Session).params()
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := m.client.mutationRaw(ctx, wirev1.SessionOpen, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[*Session]{}, err
	}
	snapshot, err := decodeValue[SessionSnapshot](raw.value, "session")
	if err != nil {
		return MutationResult[*Session]{}, err
	}
	selector := SelectID(snapshot.ID)
	handle := &Session{
		client: m.client, machine: m.selector, selector: selector,
		route: m.route.withSession(selector), snapshot: &snapshot,
	}
	return MutationResult[*Session]{
		Value: handle, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}

func (s *Session) Snapshot(ctx context.Context, options SessionSnapshotOptions) (Document, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return s.client.readDocument(ctx, wirev1.SessionSnapshot, input)
}
func (s *Session) Events(ctx context.Context, options SessionEventsOptions) (*Stream[SessionEvent], error) {
	input := s.route.params()
	if options.Cursor != nil {
		input[wirev1.FieldCursor] = options.Cursor
	}
	merge(input, options.Extra)
	return openStream(ctx, s.client, wirev1.SessionEvents, input, decodeSessionEvent)
}
func (s *Session) Ping(ctx context.Context, options SessionPingOptions) (Document, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return s.client.readDocument(ctx, wirev1.SessionPing, input)
}
func (s *Session) Shutdown(ctx context.Context, options SessionShutdownOptions) (MutationResult[ShutdownResult], error) {
	input := s.route.params()
	if options.Force != nil {
		input[wirev1.FieldForce] = *options.Force
	}
	merge(input, options.Extra)
	return mutationValue[ShutdownResult](
		ctx, s.client, wirev1.SessionShutdown, input, options.MutationOptions,
		"shutdown result",
	)
}
func (s *Session) ReloadConfig(ctx context.Context, options SessionReloadConfigOptions) (MutationResult[ReloadConfigResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[ReloadConfigResult](
		ctx, s.client, wirev1.SessionReloadConfig, input, options.MutationOptions,
		"reload config result",
	)
}
func (s *Session) UpdateTerminalDefaults(ctx context.Context, options SessionTerminalDefaultsUpdateOptions) (MutationResult[TerminalDefaultsSnapshot], error) {
	input := s.route.params()
	merge(input, options.Extra)
	for key, value := range map[string]NullableString{
		"foreground":           options.Foreground,
		"background":           options.Background,
		"cursor":               options.Cursor,
		"selection_background": options.SelectionBackground,
		"selection_foreground": options.SelectionForeground,
		"cursor_style":         options.CursorStyle,
	} {
		if value.Present {
			input[key] = value.Value
		}
	}
	if options.CursorBlink.Present {
		input["cursor_blink"] = options.CursorBlink.Value
	}
	if options.Palette.Present {
		input["palette"] = options.Palette.Value
	}
	if options.Complete {
		input["complete"] = true
	}
	return mutationValue[TerminalDefaultsSnapshot](
		ctx, s.client, wirev1.SessionTerminalDefaultsUpdate, input,
		options.MutationOptions, "terminal defaults snapshot",
	)
}
func (s *Session) SetWindowTitle(ctx context.Context, options SessionWindowTitleSetOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	input[wirev1.FieldTitle] = options.Title
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev1.SessionWindowTitleSet, input, options.MutationOptions,
		"empty result",
	)
}
func (s *Session) ClearWindowTitle(ctx context.Context, options SessionWindowTitleClearOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev1.SessionWindowTitleClear, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListConnectedClients(ctx context.Context, options ConnectedClientListOptions) ([]ConnectedClientSnapshot, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.ClientList, input, "", &raw); err != nil {
		return nil, err
	}
	return decodeList[ConnectedClientSnapshot](raw, "clients")
}
func (c *ConnectedClient) Refresh(ctx context.Context) (ConnectedClientSnapshot, error) {
	input := c.route.params()
	var snapshot ConnectedClientSnapshot
	if err := c.client.readResource(ctx, wirev1.ClientGet, input, &snapshot); err != nil {
		return ConnectedClientSnapshot{}, err
	}
	return snapshot, nil
}
func (c *ConnectedClient) UpdateMetadata(ctx context.Context, options ConnectedClientMetadataUpdateOptions) (Document, error) {
	input := c.route.params()
	if options.Name.Present {
		input[wirev1.FieldName] = options.Name.Value
	}
	if options.Kind.Present {
		input[wirev1.FieldKind] = options.Kind.Value
	}
	merge(input, options.Extra)
	return c.client.controlDocument(ctx, wirev1.ClientMetadataUpdate, input)
}
func (c *ConnectedClient) SetSizing(ctx context.Context, options ConnectedClientSizingSetOptions) (Document, error) {
	input := c.route.params()
	input[wirev1.FieldEnabled] = options.Enabled
	if options.Exclusive != nil {
		input["exclusive"] = *options.Exclusive
	}
	merge(input, options.Extra)
	return c.client.controlDocument(ctx, wirev1.ClientSizingSet, input)
}
func (c *ConnectedClient) ReleaseSizing(ctx context.Context, options ConnectedClientSizingReleaseOptions) (Document, error) {
	input := c.route.params()
	merge(input, options.Extra)
	return c.client.controlDocument(ctx, wirev1.ClientSizingRelease, input)
}
func (c *ConnectedClient) SetCellPixels(ctx context.Context, options ConnectedClientCellPixelsSetOptions) (Document, error) {
	input := c.route.params()
	input["width_px"] = options.WidthPX
	input["height_px"] = options.HeightPX
	merge(input, options.Extra)
	return c.client.controlDocument(ctx, wirev1.ClientCellPixelsSet, input)
}
func (c *ConnectedClient) Detach(ctx context.Context, options ConnectedClientDetachOptions) (Document, error) {
	input := c.route.params()
	merge(input, options.Extra)
	return c.client.controlDocument(ctx, wirev1.ClientDetach, input)
}

func (s *Session) ListPairingRequests(ctx context.Context, options PairingRequestListOptions) ([]PairingRequest, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.PairingRequestList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[PairingRequestSnapshot](raw, "pairing_requests")
	if err != nil {
		return nil, err
	}
	result := make([]PairingRequest, 0, len(snapshots))
	for _, snapshot := range snapshots {
		selector := SelectID(snapshot.ID)
		result = append(result, PairingRequest{
			client: s.client, session: s.selector,
			route: s.route.withPairingRequest(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (p *PairingRequest) Resolve(ctx context.Context, options PairingRequestResolveOptions) (MutationResult[PairingResolutionResult], error) {
	input := p.route.params()
	input["decision"] = options.Decision
	merge(input, options.Extra)
	return mutationValue[PairingResolutionResult](
		ctx, p.client, wirev1.PairingRequestResolve, input, options.MutationOptions,
		"pairing resolution result",
	)
}
func (s *Session) Projection(ctx context.Context, options FrontendProjectionGetOptions) (*FrontendProjection, error) {
	input := s.route.withProjection(options.Projection).params()
	merge(input, options.Extra)
	var snapshot FrontendProjectionSnapshot
	if err := s.client.readResource(ctx, wirev1.ProjectionGet, input, &snapshot); err != nil {
		return nil, err
	}
	selector := SelectID(snapshot.ID)
	return &FrontendProjection{
		client: s.client, session: s.selector,
		route: s.route.withProjection(selector), snapshot: snapshot,
	}, nil
}
func (p *FrontendProjection) Put(ctx context.Context, options FrontendProjectionPutOptions) (MutationResult[FrontendProjectionSnapshot], error) {
	input := p.route.params()
	input["projection"] = options.Projection
	merge(input, options.Extra)
	return mutationValue[FrontendProjectionSnapshot](
		ctx, p.client, wirev1.ProjectionPut, input, options.MutationOptions,
		"frontend projection snapshot",
	)
}

func (s *Session) ListWorkspaces(ctx context.Context, options WorkspaceListOptions) ([]*Workspace, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.WorkspaceList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[WorkspaceSnapshot](raw, "workspaces")
	if err != nil {
		return nil, err
	}
	result := make([]*Workspace, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Workspace{
			client: s.client, session: s.selector, selector: selector,
			route: s.route.withWorkspace(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (s *Session) FindWorkspacesByName(ctx context.Context, name string) ([]*Workspace, error) {
	values, err := s.ListWorkspaces(ctx, WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Workspace, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && snapshot.Name == name {
			result = append(result, value)
		}
	}
	return result, nil
}
func (s *Session) CreateWorkspace(ctx context.Context, options WorkspaceCreateOptions) (MutationResult[CreatedPath], error) {
	input := s.route.params()
	putOptionalString(input, wirev1.FieldName, options.Name)
	input[wirev1.FieldInitialContent] = options.InitialContent
	merge(input, options.Extra)
	return s.client.created(ctx, wirev1.WorkspaceCreate, input, options.MutationOptions)
}
func (w *Workspace) Rename(ctx context.Context, options WorkspaceRenameOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := w.route.params()
	input[wirev1.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, w.client, wirev1.WorkspaceRename, input, options.MutationOptions,
		"workspace snapshot",
	)
}
func (w *Workspace) Move(ctx context.Context, options WorkspaceMoveOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := w.route.params()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, w.client, wirev1.WorkspaceMove, input, options.MutationOptions,
		"workspace snapshot",
	)
}
func (w *Workspace) Focus(ctx context.Context, options WorkspaceFocusOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := w.route.params()
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, w.client, wirev1.WorkspaceFocus, input, options.MutationOptions,
		"workspace snapshot",
	)
}
func (w *Workspace) Close(ctx context.Context, options WorkspaceCloseOptions) (MutationResult[EmptyResult], error) {
	input := w.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, w.client, wirev1.WorkspaceClose, input, options.MutationOptions,
		"empty result",
	)
}
func (w *Workspace) Run(ctx context.Context, options WorkspaceRunOptions) (MutationResult[CreatedPath], error) {
	if options.Command == nil {
		return MutationResult[CreatedPath]{}, fmt.Errorf("%w: command is required", ErrInvalidArgument)
	}
	if err := options.Command.validate(); err != nil {
		return MutationResult[CreatedPath]{}, err
	}
	input := w.route.params()
	putCommand(input, options.Command)
	putOptionalString(input, wirev1.FieldCWD, options.CWD)
	putOptionalString(input, wirev1.FieldName, options.Name)
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return w.client.created(ctx, wirev1.WorkspaceRun, input, options.MutationOptions)
}
func (w *Workspace) ApplyLayout(ctx context.Context, options WorkspaceLayoutApplyOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := w.route.params()
	input[wirev1.FieldLayout] = options.Layout
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, w.client, wirev1.WorkspaceLayoutApply, input, options.MutationOptions,
		"workspace snapshot",
	)
}

func merge(target, extra map[string]any) {
	for key, value := range extra {
		if _, exists := target[key]; !exists {
			target[key] = value
		}
	}
}

func optionalNameMatches(value *string, expected string) bool {
	return value != nil && *value == expected
}

func putCommand(target map[string]any, command Command) {
	switch value := command.(type) {
	case ExactCommand:
		target[wirev1.FieldArgv] = append([]string(nil), value.Argv...)
	case *ExactCommand:
		target[wirev1.FieldArgv] = append([]string(nil), value.Argv...)
	case ShellCommand:
		target["shell"] = value.Script
	case *ShellCommand:
		target["shell"] = value.Script
	}
}

func decodeValue[T any](raw json.RawMessage, label string) (T, error) {
	var zero T
	if err := strictDecode(raw, &zero); err != nil {
		return zero, &ProtocolError{
			Message: "cannot decode " + label + ": " + err.Error(),
		}
	}
	return zero, nil
}

func (w *Workspace) ListScreens(ctx context.Context, options ScreenListOptions) ([]*Screen, error) {
	input := w.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := w.client.do(ctx, wirev1.ScreenList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[ScreenSnapshot](raw, "screens")
	if err != nil {
		return nil, err
	}
	result := make([]*Screen, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Screen{
			client: w.client, workspace: w.selector, selector: selector,
			route: w.route.withScreen(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (w *Workspace) FindScreensByName(ctx context.Context, name string) ([]*Screen, error) {
	values, err := w.ListScreens(ctx, ScreenListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Screen, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && optionalNameMatches(snapshot.Name, name) {
			result = append(result, value)
		}
	}
	return result, nil
}
func (w *Workspace) CreateScreen(ctx context.Context, options ScreenCreateOptions) (MutationResult[CreatedPath], error) {
	input := w.route.params()
	putOptionalString(input, wirev1.FieldName, options.Name)
	merge(input, options.Extra)
	return w.client.created(ctx, wirev1.ScreenCreate, input, options.MutationOptions)
}
func (s *Screen) Rename(ctx context.Context, options ScreenRenameOptions) (MutationResult[ScreenSnapshot], error) {
	input := s.route.params()
	input[wirev1.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationValue[ScreenSnapshot](
		ctx, s.client, wirev1.ScreenRename, input, options.MutationOptions,
		"screen snapshot",
	)
}
func (s *Screen) Focus(ctx context.Context, options ScreenFocusOptions) (MutationResult[ScreenSnapshot], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[ScreenSnapshot](
		ctx, s.client, wirev1.ScreenFocus, input, options.MutationOptions,
		"screen snapshot",
	)
}
func (s *Screen) Close(ctx context.Context, options ScreenCloseOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev1.ScreenClose, input, options.MutationOptions,
		"empty result",
	)
}
func (s *Screen) ExportLayout(ctx context.Context, options ScreenLayoutExportOptions) (Document, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return s.client.readDocument(ctx, wirev1.ScreenLayoutExport, input)
}
func (s *Screen) UndoLayout(ctx context.Context, options ScreenLayoutUndoOptions) (MutationResult[ScreenSnapshot], error) {
	input := s.route.params()
	if options.ConfirmClose {
		input["confirm_close"] = true
	}
	merge(input, options.Extra)
	return mutationValue[ScreenSnapshot](
		ctx, s.client, wirev1.ScreenLayoutUndo, input, options.MutationOptions,
		"screen snapshot",
	)
}

func (s *Screen) ListPanes(ctx context.Context, options PaneListOptions) ([]*Pane, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.PaneList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[PaneSnapshot](raw, "panes")
	if err != nil {
		return nil, err
	}
	result := make([]*Pane, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Pane{
			client: s.client, screen: s.selector, selector: selector,
			route: s.route.withPane(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (s *Screen) FindPanesByName(ctx context.Context, name string) ([]*Pane, error) {
	values, err := s.ListPanes(ctx, PaneListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Pane, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && optionalNameMatches(snapshot.Name, name) {
			result = append(result, value)
		}
	}
	return result, nil
}
func (s *Screen) CreatePane(ctx context.Context, options PaneCreateOptions) (MutationResult[CreatedPath], error) {
	input := s.route.params()
	putOptionalString(input, wirev1.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return s.client.created(ctx, wirev1.PaneCreate, input, options.MutationOptions)
}
func (p *Pane) Split(ctx context.Context, options PaneSplitOptions) (MutationResult[CreatedPath], error) {
	input := p.route.params()
	input[wirev1.FieldDirection] = options.Direction
	if options.Ratio != nil {
		input[wirev1.FieldRatio] = *options.Ratio
	}
	putOptionalString(input, wirev1.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev1.PaneSplit, input, options.MutationOptions)
}
func (p *Pane) Rename(ctx context.Context, options PaneRenameOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	input[wirev1.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneRename, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) Focus(ctx context.Context, options PaneFocusOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneFocus, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) FocusDirection(ctx context.Context, options PaneFocusDirectionOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	input[wirev1.FieldDirection] = options.Direction
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneFocusDirection, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) Neighbor(ctx context.Context, options PaneNeighborGetOptions) (*Pane, error) {
	input := p.route.params()
	input[wirev1.FieldDirection] = options.Direction
	merge(input, options.Extra)
	var snapshot PaneSnapshot
	if err := p.client.readResource(ctx, wirev1.PaneNeighborGet, input, &snapshot); err != nil {
		return nil, err
	}
	selector := SelectID(snapshot.ID)
	return &Pane{
		client: p.client, screen: p.screen, selector: selector,
		route: p.route.withPane(selector), snapshot: &snapshot,
	}, nil
}
func (p *Pane) Swap(ctx context.Context, options PaneSwapOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	input["other_workspace"] = options.OtherWorkspace.String()
	input["other_screen"] = options.OtherScreen.String()
	input["other_pane"] = options.OtherPane.String()
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneSwap, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) Zoom(ctx context.Context, options PaneZoomOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	if options.Enabled != nil {
		input[wirev1.FieldEnabled] = *options.Enabled
	}
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneZoom, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) SetSplitRatio(ctx context.Context, options PaneSplitRatioSetOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	input["split_id"] = options.SplitID
	input[wirev1.FieldRatio] = options.Ratio
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneSplitRatioSet, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) SetViewportWidth(ctx context.Context, options PaneViewportWidthSetOptions) (MutationResult[PaneSnapshot], error) {
	input := p.route.params()
	input["columns"] = options.Columns
	merge(input, options.Extra)
	return mutationValue[PaneSnapshot](
		ctx, p.client, wirev1.PaneViewportWidthSet, input, options.MutationOptions,
		"pane snapshot",
	)
}
func (p *Pane) Close(ctx context.Context, options PaneCloseOptions) (MutationResult[EmptyResult], error) {
	input := p.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, p.client, wirev1.PaneClose, input, options.MutationOptions,
		"empty result",
	)
}
func (p *Pane) Run(ctx context.Context, options PaneRunOptions) (MutationResult[CreatedPath], error) {
	if options.Command == nil {
		return MutationResult[CreatedPath]{}, fmt.Errorf("%w: command is required", ErrInvalidArgument)
	}
	if err := options.Command.validate(); err != nil {
		return MutationResult[CreatedPath]{}, err
	}
	input := p.route.params()
	putCommand(input, options.Command)
	putOptionalString(input, wirev1.FieldCWD, options.CWD)
	putOptionalString(input, wirev1.FieldName, options.Name)
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev1.PaneRun, input, options.MutationOptions)
}

func (p *Pane) ListTabs(ctx context.Context, options TabListOptions) ([]*Tab, error) {
	input := p.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := p.client.do(ctx, wirev1.TabList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[TabSnapshot](raw, "tabs")
	if err != nil {
		return nil, err
	}
	result := make([]*Tab, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Tab{
			client: p.client, pane: p.selector, selector: selector,
			route: p.route.withTab(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (p *Pane) FindTabsByName(ctx context.Context, name string) ([]*Tab, error) {
	values, err := p.ListTabs(ctx, TabListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Tab, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && optionalNameMatches(snapshot.Name, name) {
			result = append(result, value)
		}
	}
	return result, nil
}
func (p *Pane) CreateTerminalTab(ctx context.Context, options TabCreateTerminalOptions) (MutationResult[CreatedPath], error) {
	input := p.route.params()
	putOptionalString(input, wirev1.FieldName, options.Name)
	putOptionalString(input, wirev1.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev1.TabCreateTerminal, input, options.MutationOptions)
}
func (p *Pane) CreateBrowserTab(ctx context.Context, options TabCreateBrowserOptions) (MutationResult[CreatedPath], error) {
	input := p.route.params()
	putOptionalString(input, wirev1.FieldName, options.Name)
	input[wirev1.FieldURL] = options.URL
	if options.WidthPX != nil {
		input["width_px"] = *options.WidthPX
	}
	if options.HeightPX != nil {
		input["height_px"] = *options.HeightPX
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev1.TabCreateBrowser, input, options.MutationOptions)
}
func (t *Tab) Rename(ctx context.Context, options TabRenameOptions) (MutationResult[TabSnapshot], error) {
	input := t.route.params()
	input[wirev1.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationValue[TabSnapshot](
		ctx, t.client, wirev1.TabRename, input, options.MutationOptions,
		"tab snapshot",
	)
}
func (t *Tab) Move(ctx context.Context, options TabMoveOptions) (MutationResult[TabSnapshot], error) {
	input := t.route.params()
	input["destination_workspace"] = options.DestinationWorkspace.String()
	input["destination_screen"] = options.DestinationScreen.String()
	input["destination_pane"] = options.DestinationPane.String()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationValue[TabSnapshot](
		ctx, t.client, wirev1.TabMove, input, options.MutationOptions,
		"tab snapshot",
	)
}
func (t *Tab) Focus(ctx context.Context, options TabFocusOptions) (MutationResult[TabSnapshot], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[TabSnapshot](
		ctx, t.client, wirev1.TabFocus, input, options.MutationOptions,
		"tab snapshot",
	)
}
func (t *Tab) Close(ctx context.Context, options TabCloseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TabClose, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListTerminals(ctx context.Context, options TerminalListOptions) ([]*Terminal, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.TerminalList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[TerminalSnapshot](raw, "terminals")
	if err != nil {
		return nil, err
	}
	result := make([]*Terminal, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Terminal{
			client: s.client, selector: selector,
			route: s.route.withTerminal(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (s *Session) FindTerminalsByName(ctx context.Context, name string) ([]*Terminal, error) {
	values, err := s.ListTerminals(ctx, TerminalListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Terminal, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && snapshot.Title == name {
			result = append(result, value)
		}
	}
	return result, nil
}
func (t *Terminal) Write(ctx context.Context, options TerminalInputWriteOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	if (options.Text == nil) == (options.Bytes == nil) {
		return MutationResult[EmptyResult]{}, fmt.Errorf(
			"%w: exactly one of Text or Bytes is required", ErrInvalidArgument,
		)
	}
	if options.Text != nil {
		input[wirev1.FieldText] = *options.Text
	} else {
		input["bytes_base64"] = base64.StdEncoding.EncodeToString(options.Bytes)
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalInputWrite, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Keys(ctx context.Context, options TerminalInputKeysOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev1.FieldKeys] = options.Keys
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalInputKeys, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Mouse(ctx context.Context, options TerminalInputMouseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev1.FieldKind] = options.Kind
	input["row"] = options.Row
	input["column"] = options.Column
	if options.Button != nil {
		input["button"] = *options.Button
	}
	if options.DeltaRows != nil {
		input["delta_rows"] = *options.DeltaRows
	}
	if options.Modifiers != nil {
		input["modifiers"] = options.Modifiers
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalInputMouse, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) FocusInput(ctx context.Context, options TerminalInputFocusOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev1.FieldFocused] = options.Focused
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalInputFocus, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) ReadScreen(ctx context.Context, options TerminalScreenReadOptions) (Document, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalScreenRead, input)
}
func (t *Terminal) ReadState(ctx context.Context, options TerminalStateReadOptions) (Document, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalStateRead, input)
}
func (t *Terminal) ReadHistory(ctx context.Context, options TerminalHistoryReadOptions) (Document, error) {
	input := t.route.params()
	if options.Before != nil {
		input["before"] = *options.Before
	}
	if options.Limit != nil {
		input["limit"] = *options.Limit
	}
	if options.Styled != nil {
		input["styled"] = *options.Styled
	}
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalHistoryRead, input)
}
func (t *Terminal) ClearHistory(ctx context.Context, options TerminalHistoryClearOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalHistoryClear, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Wait(ctx context.Context, options TerminalWaitOptions) (Document, error) {
	input := t.route.params()
	input["pattern"] = options.Pattern
	if options.TimeoutMS != nil {
		input[wirev1.FieldTimeoutMS] = *options.TimeoutMS
	}
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalWait, input)
}
func (t *Terminal) Copy(ctx context.Context, options TerminalCopyOptions) (Document, error) {
	input := t.route.params()
	if options.Mode != nil {
		input[wirev1.FieldMode] = *options.Mode
	}
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalCopy, input)
}
func (t *Terminal) Process(ctx context.Context, options TerminalProcessGetOptions) (Document, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return t.client.readDocument(ctx, wirev1.TerminalProcessGet, input)
}
func (t *Terminal) CreateRendererGrant(ctx context.Context, options TerminalRendererGrantCreateOptions) (RendererGrant, error) {
	input := t.route.params()
	if options.TTLMS != nil {
		input["ttl_ms"] = *options.TTLMS
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := t.client.do(ctx, wirev1.TerminalRendererGrantCreate, input, "", &raw); err != nil {
		return RendererGrant{}, err
	}
	return decodeRendererGrant(raw)
}
func (t *Terminal) ResizeViewer(ctx context.Context, options TerminalViewerResizeOptions) (Document, error) {
	input := t.route.params()
	input[wirev1.FieldCols] = options.Cols
	input[wirev1.FieldRows] = options.Rows
	merge(input, options.Extra)
	return t.client.controlDocument(ctx, wirev1.TerminalViewerResize, input)
}
func (t *Terminal) ReleaseViewer(ctx context.Context, options TerminalViewerReleaseOptions) (Document, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return t.client.controlDocument(ctx, wirev1.TerminalViewerRelease, input)
}
func (t *Terminal) ScrollViewport(ctx context.Context, options TerminalViewportScrollOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input["delta_rows"] = options.DeltaRows
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalViewportScroll, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Move(ctx context.Context, options TerminalMoveOptions) (MutationResult[TerminalSnapshot], error) {
	input := t.route.params()
	input["destination_workspace"] = options.DestinationWorkspace.String()
	input["destination_screen"] = options.DestinationScreen.String()
	input["destination_pane"] = options.DestinationPane.String()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationValue[TerminalSnapshot](
		ctx, t.client, wirev1.TerminalMove, input, options.MutationOptions,
		"terminal snapshot",
	)
}
func (t *Terminal) Attach(ctx context.Context, options TerminalAttachOptions) (*Stream[TerminalAttachmentItem], error) {
	input := t.route.params()
	if options.Cols != nil {
		input[wirev1.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev1.FieldRows] = *options.Rows
	}
	if options.ReadOnly != nil {
		input["read_only"] = *options.ReadOnly
	}
	merge(input, options.Extra)
	return openStream(ctx, t.client, wirev1.TerminalAttach, input, decodeTerminalAttachment)
}
func (t *Terminal) Close(ctx context.Context, options TerminalCloseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev1.TerminalClose, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListBrowsers(ctx context.Context, options BrowserListOptions) ([]*Browser, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.BrowserList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[BrowserSnapshot](raw, "browsers")
	if err != nil {
		return nil, err
	}
	result := make([]*Browser, 0, len(snapshots))
	for index := range snapshots {
		snapshot := &snapshots[index]
		selector := SelectID(snapshot.ID)
		result = append(result, &Browser{
			client: s.client, selector: selector,
			route: s.route.withBrowser(selector), snapshot: snapshot,
		})
	}
	return result, nil
}
func (s *Session) FindBrowsersByName(ctx context.Context, name string) ([]*Browser, error) {
	values, err := s.ListBrowsers(ctx, BrowserListOptions{})
	if err != nil {
		return nil, err
	}
	result := make([]*Browser, 0)
	for _, value := range values {
		if snapshot, ok := value.Cached(); ok && snapshot.Title == name {
			result = append(result, value)
		}
	}
	return result, nil
}
func (b *Browser) Navigate(ctx context.Context, options BrowserNavigateOptions) (MutationResult[BrowserSnapshot], error) {
	input := b.route.params()
	input[wirev1.FieldURL] = options.URL
	merge(input, options.Extra)
	return mutationValue[BrowserSnapshot](
		ctx, b.client, wirev1.BrowserNavigate, input, options.MutationOptions,
		"browser snapshot",
	)
}
func (b *Browser) Back(ctx context.Context, options BrowserBackOptions) (MutationResult[BrowserSnapshot], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[BrowserSnapshot](
		ctx, b.client, wirev1.BrowserBack, input, options.MutationOptions,
		"browser snapshot",
	)
}
func (b *Browser) Forward(ctx context.Context, options BrowserForwardOptions) (MutationResult[BrowserSnapshot], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[BrowserSnapshot](
		ctx, b.client, wirev1.BrowserForward, input, options.MutationOptions,
		"browser snapshot",
	)
}
func (b *Browser) Reload(ctx context.Context, options BrowserReloadOptions) (MutationResult[BrowserSnapshot], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[BrowserSnapshot](
		ctx, b.client, wirev1.BrowserReload, input, options.MutationOptions,
		"browser snapshot",
	)
}
func (b *Browser) Activate(ctx context.Context, options BrowserActivateOptions) (MutationResult[BrowserSnapshot], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[BrowserSnapshot](
		ctx, b.client, wirev1.BrowserActivate, input, options.MutationOptions,
		"browser snapshot",
	)
}
func (b *Browser) Key(ctx context.Context, options BrowserInputKeyOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input["key"] = options.Key
	if options.Kind != nil {
		input[wirev1.FieldKind] = *options.Kind
	}
	if options.Modifiers != nil {
		input["modifiers"] = options.Modifiers
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev1.BrowserInputKey, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Text(ctx context.Context, options BrowserInputTextOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input[wirev1.FieldText] = options.Text
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev1.BrowserInputText, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Mouse(ctx context.Context, options BrowserInputMouseOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input[wirev1.FieldKind] = options.Kind
	input["x_px"] = options.XPX
	input["y_px"] = options.YPX
	if options.Button != nil {
		input["button"] = *options.Button
	}
	if options.ClickCount != nil {
		input["click_count"] = *options.ClickCount
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev1.BrowserInputMouse, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Wheel(ctx context.Context, options BrowserInputWheelOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input["delta_x"] = options.DeltaX
	input["delta_y"] = options.DeltaY
	input["x_px"] = options.XPX
	input["y_px"] = options.YPX
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev1.BrowserInputWheel, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) ResizeViewer(ctx context.Context, options BrowserViewerResizeOptions) (Document, error) {
	input := b.route.params()
	input["width_px"] = options.WidthPX
	input["height_px"] = options.HeightPX
	merge(input, options.Extra)
	return b.client.controlDocument(ctx, wirev1.BrowserViewerResize, input)
}
func (b *Browser) ReleaseViewer(ctx context.Context, options BrowserViewerReleaseOptions) (Document, error) {
	input := b.route.params()
	merge(input, options.Extra)
	return b.client.controlDocument(ctx, wirev1.BrowserViewerRelease, input)
}
func (b *Browser) Attach(ctx context.Context, options BrowserAttachOptions) (*Stream[BrowserAttachmentItem], error) {
	input := b.route.params()
	if options.WidthPX != nil {
		input["width_px"] = *options.WidthPX
	}
	if options.HeightPX != nil {
		input["height_px"] = *options.HeightPX
	}
	merge(input, options.Extra)
	return openStream(ctx, b.client, wirev1.BrowserAttach, input, decodeBrowserAttachment)
}
func (b *Browser) Close(ctx context.Context, options BrowserCloseOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev1.BrowserClose, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListNotifications(ctx context.Context, options NotificationListOptions) ([]Notification, error) {
	input := s.route.params()
	if options.Limit != nil {
		input["limit"] = *options.Limit
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.NotificationList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[NotificationSnapshot](raw, "notifications")
	if err != nil {
		return nil, err
	}
	result := make([]Notification, 0, len(snapshots))
	for _, snapshot := range snapshots {
		result = append(result, Notification{
			client: s.client, session: s.selector, route: s.route,
			snapshot: snapshot,
		})
	}
	return result, nil
}
func (s *Session) CreateNotification(ctx context.Context, options NotificationCreateOptions) (MutationResult[*Notification], error) {
	input := s.route.params()
	input[wirev1.FieldTitle] = options.Title
	input[wirev1.FieldBody] = options.Body
	if options.Level != nil {
		input[wirev1.FieldLevel] = *options.Level
	}
	if options.TerminalID != nil {
		input["terminal_id"] = *options.TerminalID
	}
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := s.client.mutationRaw(ctx, wirev1.NotificationCreate, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[*Notification]{}, err
	}
	snapshot, err := decodeValue[NotificationSnapshot](raw.value, "notification")
	if err != nil {
		return MutationResult[*Notification]{}, err
	}
	value := &Notification{
		client: s.client, session: s.selector, route: s.route, snapshot: snapshot,
	}
	return MutationResult[*Notification]{
		Value: value, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}

func (s *Session) ListAgents(ctx context.Context, options AgentListOptions) ([]Agent, error) {
	input := s.route.params()
	if options.TerminalID != nil {
		input["terminal_id"] = *options.TerminalID
	}
	if options.State != nil {
		input[wirev1.FieldState] = *options.State
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev1.AgentList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[AgentSnapshot](raw, "agents")
	if err != nil {
		return nil, err
	}
	result := make([]Agent, 0, len(snapshots))
	for _, snapshot := range snapshots {
		result = append(result, Agent{
			client: s.client, session: s.selector, route: s.route,
			snapshot: snapshot,
		})
	}
	return result, nil
}
func (a *Agent) Report(ctx context.Context, options AgentReportOptions) (MutationResult[AgentSnapshot], error) {
	input := a.route.params()
	input["terminal_id"] = options.TerminalID
	input[wirev1.FieldState] = options.State
	input["source"] = options.Source
	if options.SourceSession != nil {
		input["source_session"] = *options.SourceSession
	}
	merge(input, options.Extra)
	return mutationValue[AgentSnapshot](
		ctx, a.client, wirev1.AgentReport, input, options.MutationOptions,
		"agent snapshot",
	)
}

func (s *SidebarView) Refresh(ctx context.Context, options SidebarViewGetOptions) (SidebarViewSnapshot, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var snapshot SidebarViewSnapshot
	if err := s.client.readResource(ctx, wirev1.SidebarViewGet, input, &snapshot); err != nil {
		return SidebarViewSnapshot{}, err
	}
	return snapshot, nil
}
func (s *Session) EnsureSidebarView(ctx context.Context, options SidebarViewEnsureOptions) (MutationResult[*SidebarView], error) {
	input := s.route.params()
	input[wirev1.FieldCols] = options.Cols
	input[wirev1.FieldRows] = options.Rows
	if options.Relaunch != nil {
		input["relaunch"] = *options.Relaunch
	}
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := s.client.mutationRaw(ctx, wirev1.SidebarViewEnsure, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[*SidebarView]{}, err
	}
	snapshot, err := decodeValue[SidebarViewSnapshot](raw.value, "sidebar view")
	if err != nil {
		return MutationResult[*SidebarView]{}, err
	}
	value := &SidebarView{
		client: s.client, session: s.selector, selector: SelectID(snapshot.ID),
		route: s.route.withSidebarView(SelectID(snapshot.ID)),
	}
	return MutationResult[*SidebarView]{
		Value: value, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}
func (s *SidebarView) Attach(ctx context.Context, options SidebarViewAttachOptions) (*Stream[SidebarViewItem], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return openStream(ctx, s.client, wirev1.SidebarViewAttach, input, decodeSidebarViewItem)
}
func (s *SidebarView) Input(ctx context.Context, options SidebarViewInputOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	input["data_base64"] = base64.StdEncoding.EncodeToString(options.Data)
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev1.SidebarViewInput, input, options.MutationOptions,
		"empty result",
	)
}
func (s *SidebarView) Resize(ctx context.Context, options SidebarViewResizeOptions) (MutationResult[SidebarViewSnapshot], error) {
	input := s.route.params()
	input[wirev1.FieldCols] = options.Cols
	input[wirev1.FieldRows] = options.Rows
	merge(input, options.Extra)
	return mutationValue[SidebarViewSnapshot](
		ctx, s.client, wirev1.SidebarViewResize, input, options.MutationOptions,
		"sidebar view snapshot",
	)
}
func (s *SidebarView) Reload(ctx context.Context, options SidebarViewReloadOptions) (MutationResult[SidebarViewSnapshot], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[SidebarViewSnapshot](
		ctx, s.client, wirev1.SidebarViewReload, input, options.MutationOptions,
		"sidebar view snapshot",
	)
}

func (c *Client) ListProviderScopes(ctx context.Context, options ProviderScopeListOptions) ([]ProviderScope, error) {
	input := map[string]any{}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := c.do(ctx, wirev1.ProviderScopeList, input, "", &raw); err != nil {
		return nil, err
	}
	snapshots, err := decodeList[ProviderScopeSnapshot](raw, "provider_scopes")
	if err != nil {
		return nil, err
	}
	result := make([]ProviderScope, 0, len(snapshots))
	for _, snapshot := range snapshots {
		selector := SelectID(snapshot.ID)
		result = append(result, ProviderScope{
			client: c, selector: selector,
			route: resourceRoute{}.
				withMachine(SelectCurrent[MachineID]()).
				withProviderScope(selector),
			snapshot: snapshot,
		})
	}
	return result, nil
}
func (a *ProviderAction) Invoke(ctx context.Context, options ProviderActionInvokeOptions) (MutationResult[any], error) {
	input := a.route.params()
	input["parameters"] = options.Parameters
	merge(input, options.Extra)
	return mutationValue[any](
		ctx, a.client, wirev1.ProviderActionInvoke, input, options.MutationOptions,
		"provider action result",
	)
}
func (s *ProviderScope) Notices(ctx context.Context, options ProviderNoticeEventsOptions) (*Stream[ProviderNoticeItem], error) {
	input := s.route.params()
	if options.Cursor != nil {
		input[wirev1.FieldCursor] = options.Cursor
	}
	merge(input, options.Extra)
	return openStream(ctx, s.client, wirev1.ProviderNoticeEvents, input, func(raw json.RawMessage) (ProviderNoticeItem, error) {
		fields, err := decodeFields(raw)
		if err != nil {
			return ProviderNoticeItem{}, err
		}
		kind, ok := fields["kind"].(string)
		if !ok || kind == "" {
			return ProviderNoticeItem{}, &ProtocolError{
				Message: "provider notice item omitted kind",
			}
		}
		if kind != "notice" {
			return ProviderNoticeItem{Kind: kind, Raw: fields}, nil
		}
		var known struct {
			Kind     string                 `json:"kind"`
			Notice   ProviderNoticeSnapshot `json:"notice"`
			Sequence Decimal                `json:"sequence"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return ProviderNoticeItem{}, &ProtocolError{
				Message: "cannot decode provider notice item: " + err.Error(),
			}
		}
		selector := SelectID(known.Notice.ID)
		handle := &ProviderNotice{
			client: s.client, selector: selector,
			route: s.route.withProviderNotice(selector), snapshot: known.Notice,
		}
		return ProviderNoticeItem{
			Kind: kind, Notice: handle, Sequence: known.Sequence,
		}, nil
	})
}
func (n *ProviderNotice) Acknowledge(
	ctx context.Context,
	options ProviderNoticeAcknowledgeOptions,
) (EmptyResult, error) {
	input := n.route.params()
	input["sequence"] = options.Sequence
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := n.client.do(
		ctx, wirev1.ProviderNoticeAcknowledge, input, "", &raw,
	); err != nil {
		return EmptyResult{}, err
	}
	return decodeValue[EmptyResult](raw, "provider notice acknowledgement")
}
func (s *ProviderScope) MarkWorkspace(ctx context.Context, options ProviderWorkspaceMarkOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := s.route.params()
	input[wirev1.FieldSession] = options.Session.String()
	input[wirev1.FieldWorkspace] = options.Workspace.String()
	input["managed"] = options.Managed
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, s.client, wirev1.ProviderWorkspaceMark, input, options.MutationOptions,
		"workspace snapshot",
	)
}
func (s *ProviderScope) RenameWorkspace(ctx context.Context, options ProviderWorkspaceRenameOptions) (MutationResult[WorkspaceSnapshot], error) {
	input := s.route.params()
	input[wirev1.FieldSession] = options.Session.String()
	input[wirev1.FieldWorkspace] = options.Workspace.String()
	input[wirev1.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationValue[WorkspaceSnapshot](
		ctx, s.client, wirev1.ProviderWorkspaceRename, input, options.MutationOptions,
		"workspace snapshot",
	)
}
func (s *ProviderScope) CloseWorkspace(ctx context.Context, options ProviderWorkspaceCloseOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	input[wirev1.FieldSession] = options.Session.String()
	input[wirev1.FieldWorkspace] = options.Workspace.String()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev1.ProviderWorkspaceClose, input, options.MutationOptions,
		"empty result",
	)
}

func (n Notification) Snapshot() NotificationSnapshot { return n.snapshot }
func (a Agent) Snapshot() AgentSnapshot               { return a.snapshot }
func (p PairingRequest) Snapshot() PairingRequestSnapshot {
	return p.snapshot
}
func (p FrontendProjection) Snapshot() FrontendProjectionSnapshot {
	return p.snapshot
}
func (p ProviderScope) Snapshot() ProviderScopeSnapshot { return p.snapshot }
func (p ProviderAction) Snapshot() ProviderActionSnapshot {
	return p.snapshot
}
func (p *ProviderNotice) Snapshot() ProviderNoticeSnapshot { return p.snapshot }

func decodeSessionEvent(raw json.RawMessage) (SessionEvent, error) {
	fields, err := decodeFields(raw)
	if err != nil {
		return SessionEvent{}, err
	}
	kind, ok := fields["kind"].(string)
	if !ok || kind == "" {
		return SessionEvent{}, &ProtocolError{Message: "session event kind must be a non-empty string"}
	}
	switch kind {
	case "snapshot":
		var known struct {
			Kind        string         `json:"kind"`
			Cursor      *Cursor        `json:"cursor"`
			ResetReason *string        `json:"reset_reason,omitempty"`
			Snapshot    map[string]any `json:"snapshot"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SessionEvent{}, &ProtocolError{Message: "invalid session snapshot item: " + err.Error()}
		}
		if known.Cursor == nil || known.Snapshot == nil {
			return SessionEvent{}, &ProtocolError{Message: "session snapshot item requires cursor and snapshot"}
		}
		if known.ResetReason != nil &&
			*known.ResetReason != "initial" &&
			*known.ResetReason != "generation_changed" &&
			*known.ResetReason != "cursor_expired" {
			return SessionEvent{}, &ProtocolError{Message: "invalid session snapshot reset_reason"}
		}
		return SessionEvent{
			Kind:        known.Kind,
			Cursor:      known.Cursor,
			ResetReason: known.ResetReason,
			Snapshot:    known.Snapshot,
		}, nil
	case "delta":
		var known struct {
			Kind             string            `json:"kind"`
			Cursor           *Cursor           `json:"cursor"`
			PreviousRevision *Decimal          `json:"previous_revision"`
			Revision         *Decimal          `json:"revision"`
			Changes          *[]map[string]any `json:"changes"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SessionEvent{}, &ProtocolError{Message: "invalid session delta item: " + err.Error()}
		}
		if known.Cursor == nil || known.PreviousRevision == nil ||
			known.Revision == nil || known.Changes == nil {
			return SessionEvent{}, &ProtocolError{
				Message: "session delta item requires cursor, previous_revision, revision, and changes",
			}
		}
		return SessionEvent{
			Kind:             known.Kind,
			Cursor:           known.Cursor,
			PreviousRevision: *known.PreviousRevision,
			Revision:         *known.Revision,
			Changes:          *known.Changes,
		}, nil
	default:
		return SessionEvent{Kind: kind, Raw: fields}, nil
	}
}

func decodeTerminalAttachment(raw json.RawMessage) (TerminalAttachmentItem, error) {
	fields, err := decodeFields(raw)
	if err != nil {
		return TerminalAttachmentItem{}, err
	}
	kind, ok := fields["kind"].(string)
	if !ok || kind == "" {
		return TerminalAttachmentItem{}, &ProtocolError{
			Message: "terminal attachment kind must be a non-empty string",
		}
	}
	switch kind {
	case "snapshot", "patch":
		var known struct {
			Kind       string         `json:"kind"`
			TerminalID *TerminalID    `json:"terminal_id"`
			Render     map[string]any `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal " + kind + " item: " + err.Error(),
			}
		}
		if known.TerminalID == nil || known.Render == nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "terminal " + kind + " item requires terminal_id and render",
			}
		}
		return TerminalAttachmentItem{
			Kind:       known.Kind,
			TerminalID: *known.TerminalID,
			Render:     known.Render,
		}, nil
	case "scroll":
		var known struct {
			Kind       string         `json:"kind"`
			TerminalID *TerminalID    `json:"terminal_id"`
			Scroll     map[string]any `json:"scroll"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal scroll item: " + err.Error(),
			}
		}
		if known.TerminalID == nil || known.Scroll == nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "terminal scroll item requires terminal_id and scroll",
			}
		}
		return TerminalAttachmentItem{
			Kind:       known.Kind,
			TerminalID: *known.TerminalID,
			Scroll:     known.Scroll,
		}, nil
	default:
		return TerminalAttachmentItem{Kind: kind, Raw: fields}, nil
	}
}

func decodeBrowserAttachment(raw json.RawMessage) (BrowserAttachmentItem, error) {
	fields, err := decodeFields(raw)
	if err != nil {
		return BrowserAttachmentItem{}, err
	}
	kind, ok := fields["kind"].(string)
	if !ok || kind == "" {
		return BrowserAttachmentItem{}, &ProtocolError{
			Message: "browser attachment kind must be a non-empty string",
		}
	}
	switch kind {
	case "snapshot":
		var known struct {
			Kind    string           `json:"kind"`
			Browser *BrowserSnapshot `json:"browser"`
			Size    *PixelSize       `json:"size"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser snapshot item: " + err.Error(),
			}
		}
		if known.Browser == nil || known.Size == nil ||
			known.Size.WidthPX == 0 || known.Size.HeightPX == 0 {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "browser snapshot item requires browser and a non-zero size",
			}
		}
		return BrowserAttachmentItem{
			Kind:    known.Kind,
			Browser: known.Browser,
			Size:    known.Size,
		}, nil
	case "frame":
		var known struct {
			Kind       string  `json:"kind"`
			MIMEType   *string `json:"mime_type"`
			DataBase64 *string `json:"data_base64"`
			WidthPX    *uint32 `json:"width_px"`
			HeightPX   *uint32 `json:"height_px"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser frame item: " + err.Error(),
			}
		}
		if known.MIMEType == nil || known.DataBase64 == nil ||
			known.WidthPX == nil || *known.WidthPX == 0 ||
			known.HeightPX == nil || *known.HeightPX == 0 {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "browser frame item requires mime_type, data_base64, and non-zero dimensions",
			}
		}
		if *known.MIMEType != "image/png" && *known.MIMEType != "image/jpeg" {
			return BrowserAttachmentItem{}, &ProtocolError{Message: "invalid browser frame mime_type"}
		}
		frame, err := base64.StdEncoding.DecodeString(*known.DataBase64)
		if err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser frame data_base64: " + err.Error(),
			}
		}
		return BrowserAttachmentItem{
			Kind:     known.Kind,
			MIMEType: *known.MIMEType,
			Frame:    frame,
			WidthPX:  *known.WidthPX,
			HeightPX: *known.HeightPX,
		}, nil
	case "state":
		var known struct {
			Kind    string  `json:"kind"`
			URL     *string `json:"url"`
			Title   *string `json:"title"`
			Loading *bool   `json:"loading"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser state item: " + err.Error(),
			}
		}
		if known.URL == nil || known.Title == nil || known.Loading == nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "browser state item requires url, title, and loading",
			}
		}
		return BrowserAttachmentItem{
			Kind:    known.Kind,
			URL:     *known.URL,
			Title:   *known.Title,
			Loading: *known.Loading,
		}, nil
	default:
		return BrowserAttachmentItem{Kind: kind, Raw: fields}, nil
	}
}

func decodeSidebarViewItem(raw json.RawMessage) (SidebarViewItem, error) {
	fields, err := decodeFields(raw)
	if err != nil {
		return SidebarViewItem{}, err
	}
	kind, ok := fields["kind"].(string)
	if !ok || kind == "" {
		return SidebarViewItem{}, &ProtocolError{
			Message: "sidebar attachment kind must be a non-empty string",
		}
	}
	switch kind {
	case "snapshot":
		var known struct {
			Kind        string               `json:"kind"`
			SidebarView *SidebarViewSnapshot `json:"sidebar_view"`
			Render      map[string]any       `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar snapshot item: " + err.Error(),
			}
		}
		if known.SidebarView == nil || known.Render == nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar snapshot item requires sidebar_view and render",
			}
		}
		return SidebarViewItem{
			Kind:        known.Kind,
			SidebarView: known.SidebarView,
			Render:      known.Render,
		}, nil
	case "patch":
		var known struct {
			Kind          string         `json:"kind"`
			SidebarViewID *SidebarViewID `json:"sidebar_view_id"`
			Render        map[string]any `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar patch item: " + err.Error(),
			}
		}
		if known.SidebarViewID == nil || known.Render == nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar patch item requires sidebar_view_id and render",
			}
		}
		return SidebarViewItem{
			Kind:          known.Kind,
			SidebarViewID: *known.SidebarViewID,
			Render:        known.Render,
		}, nil
	case "scroll":
		var known struct {
			Kind          string         `json:"kind"`
			SidebarViewID *SidebarViewID `json:"sidebar_view_id"`
			Scroll        map[string]any `json:"scroll"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar scroll item: " + err.Error(),
			}
		}
		if known.SidebarViewID == nil || known.Scroll == nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar scroll item requires sidebar_view_id and scroll",
			}
		}
		return SidebarViewItem{
			Kind:          known.Kind,
			SidebarViewID: *known.SidebarViewID,
			Scroll:        known.Scroll,
		}, nil
	default:
		return SidebarViewItem{Kind: kind, Raw: fields}, nil
	}
}

func decodeFields(raw json.RawMessage) (map[string]any, error) {
	var fields map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&fields); err != nil {
		return nil, &ProtocolError{Message: "stream item is not an object: " + err.Error()}
	}
	return fields, nil
}

func decodeRendererGrant(raw json.RawMessage) (RendererGrant, error) {
	var result struct {
		Endpoint   string     `json:"endpoint"`
		TerminalID TerminalID `json:"terminal_id"`
		Token      string     `json:"token"`
		Rights     []string   `json:"rights"`
		TTLMS      uint32     `json:"ttl_ms"`
	}
	payload := raw
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(raw, &wrapper); err == nil {
		if nested, ok := wrapper["grant"]; ok {
			payload = nested
		}
	}
	if err := json.Unmarshal(payload, &result); err != nil {
		return RendererGrant{}, &ProtocolError{
			Message: "cannot decode renderer grant: " + err.Error(),
		}
	}
	if result.Token == "" {
		return RendererGrant{}, &ProtocolError{Message: "renderer grant omitted token"}
	}
	return RendererGrant{
		Endpoint: result.Endpoint, TerminalID: result.TerminalID,
		Token: NewSecret(result.Token), Rights: append([]string(nil), result.Rights...),
		TTLMS: result.TTLMS,
	}, nil
}
