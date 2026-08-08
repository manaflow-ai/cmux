package cmux

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"reflect"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/wirev2"
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

func readValue[T any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
	input map[string]any,
	label string,
) (T, error) {
	var raw json.RawMessage
	if err := client.do(ctx, operation, input, "", &raw); err != nil {
		var zero T
		return zero, err
	}
	return decodeValue[T](raw, label)
}

func mutationValue[T any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
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

func mutationHandle[Snapshot any, Handle any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
	input map[string]any,
	options MutationOptions,
	label string,
	cache func(Snapshot) error,
	handle Handle,
) (MutationResult[Handle], error) {
	result, err := mutationValue[Snapshot](
		ctx,
		client,
		operation,
		input,
		options,
		label,
	)
	if err != nil {
		return MutationResult[Handle]{}, err
	}
	if err := cache(result.Value); err != nil {
		return MutationResult[Handle]{}, err
	}
	return MutationResult[Handle]{
		Value: handle, Generation: result.Generation, Revision: result.Revision,
		Replayed: result.Replayed,
	}, nil
}

func mutationNewHandle[Snapshot any, Handle any](
	ctx context.Context,
	client *Client,
	operation wirev2.Operation,
	input map[string]any,
	options MutationOptions,
	label string,
	build func(Snapshot) Handle,
) (MutationResult[Handle], error) {
	result, err := mutationValue[Snapshot](ctx, client, operation, input, options, label)
	if err != nil {
		return MutationResult[Handle]{}, err
	}
	return MutationResult[Handle]{
		Value:      build(result.Value),
		Generation: result.Generation,
		Revision:   result.Revision,
		Replayed:   result.Replayed,
	}, nil
}

type mutationWireResult struct {
	value      json.RawMessage
	generation string
	revision   Decimal
	replayed   bool
}

func (c *Client) mutationRaw(
	ctx context.Context,
	operation wirev2.Operation,
	input map[string]any,
	idempotencyKey string,
) (mutationWireResult, error) {
	var fields map[string]json.RawMessage
	if err := c.do(ctx, operation, input, idempotencyKey, &fields); err != nil {
		return mutationWireResult{}, err
	}
	for key := range fields {
		switch key {
		case "value", wirev2.FieldGeneration, wirev2.FieldRevision, "replayed":
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
	generationRaw, ok := fields[wirev2.FieldGeneration]
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
	revisionRaw, ok := fields[wirev2.FieldRevision]
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
	operation wirev2.Operation,
	input map[string]any,
	options MutationOptions,
) (MutationResult[CreatedPath], error) {
	if len(options.CorrelationKey) > 128 {
		return MutationResult[CreatedPath]{}, fmt.Errorf(
			"%w: correlation key must contain 1 to 128 characters",
			ErrInvalidArgument,
		)
	}
	if options.CorrelationKey != "" {
		input["correlation_key"] = options.CorrelationKey
	}
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
	if err := c.do(ctx, wirev2.MachineList, params(options.Extra), "", &raw); err != nil {
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

func (m *Machine) ListSessions(ctx context.Context, options SessionListOptions) ([]*Session, error) {
	input := m.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := m.client.do(ctx, wirev2.SessionList, input, "", &raw); err != nil {
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
	raw, err := m.client.mutationRaw(ctx, wirev2.SessionOpen, input, options.IdempotencyKey)
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

func (s *Session) Snapshot(ctx context.Context, options SessionSnapshotOptions) (ResourceSnapshot, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return readValue[ResourceSnapshot](
		ctx, s.client, wirev2.SessionSnapshot, input, "resource snapshot",
	)
}
func (s *Session) ResolveCreation(
	ctx context.Context,
	correlationKey string,
	options SessionCreationResolveOptions,
) (CreationResolution, error) {
	if len(correlationKey) < 1 || len(correlationKey) > 128 {
		return CreationResolution{}, fmt.Errorf(
			"%w: correlation key must contain 1 to 128 characters",
			ErrInvalidArgument,
		)
	}
	input := s.route.params()
	input["correlation_key"] = correlationKey
	merge(input, options.Extra)
	result, err := readValue[CreationResolution](
		ctx, s.client, wirev2.SessionCreationResolve, input,
		"creation resolution",
	)
	if err != nil {
		return CreationResolution{}, err
	}
	if result.CorrelationKey != correlationKey {
		return CreationResolution{}, &ProtocolError{
			Message: fmt.Sprintf(
				"creation resolution returned correlation key %q for %q",
				result.CorrelationKey,
				correlationKey,
			),
		}
	}
	return result, nil
}
func (s *Session) Events(ctx context.Context, options SessionEventsOptions) (*Stream[SessionEvent], error) {
	input := s.route.params()
	if options.Cursor != nil {
		input[wirev2.FieldCursor] = options.Cursor
	}
	merge(input, options.Extra)
	return openStream(ctx, s.client, wirev2.SessionEvents, input, decodeSessionEvent)
}
func (s *Session) Journal(ctx context.Context, options SessionJournalOptions) (*Stream[SessionJournalRecord], error) {
	if err := options.validate(); err != nil {
		return nil, err
	}
	input := s.route.params()
	if options.Cursor != nil {
		input[wirev2.FieldCursor] = options.Cursor
	}
	if options.Start != nil {
		input[wirev2.FieldStart] = *options.Start
	}
	if options.Follow != nil {
		input["follow"] = *options.Follow
	}
	if options.Filter != nil {
		input["filter"] = options.Filter
	}
	merge(input, options.Extra)
	return openDecodedStream(
		ctx,
		s.client,
		wirev2.SessionJournalSubscribe,
		input,
		func(raw json.RawMessage, cursor *Cursor) (SessionJournalRecord, error) {
			record, err := decodeSessionJournalRecord(raw)
			if err != nil {
				return SessionJournalRecord{}, err
			}
			if cursor == nil || cursor.Revision != record.Sequence {
				return SessionJournalRecord{}, &ProtocolError{
					Message: "journal sequence must match its stream cursor",
				}
			}
			return record, nil
		},
	)
}
func (s *Session) Ping(ctx context.Context, options SessionPingOptions) (PingResult, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return readValue[PingResult](ctx, s.client, wirev2.SessionPing, input, "ping result")
}
func (s *Session) Shutdown(ctx context.Context, options SessionShutdownOptions) (MutationResult[ShutdownResult], error) {
	input := s.route.params()
	if options.Force != nil {
		input[wirev2.FieldForce] = *options.Force
	}
	merge(input, options.Extra)
	return mutationValue[ShutdownResult](
		ctx, s.client, wirev2.SessionShutdown, input, options.MutationOptions,
		"shutdown result",
	)
}
func (s *Session) ReloadConfig(ctx context.Context, options SessionReloadConfigOptions) (MutationResult[ReloadConfigResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[ReloadConfigResult](
		ctx, s.client, wirev2.SessionReloadConfig, input, options.MutationOptions,
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
		ctx, s.client, wirev2.SessionTerminalDefaultsUpdate, input,
		options.MutationOptions, "terminal defaults snapshot",
	)
}
func (s *Session) SetWindowTitle(ctx context.Context, options SessionWindowTitleSetOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	input[wirev2.FieldTitle] = options.Title
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev2.SessionWindowTitleSet, input, options.MutationOptions,
		"empty result",
	)
}
func (s *Session) ClearWindowTitle(ctx context.Context, options SessionWindowTitleClearOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev2.SessionWindowTitleClear, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListConnectedClients(ctx context.Context, options ConnectedClientListOptions) ([]ConnectedClientSnapshot, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.ClientList, input, "", &raw); err != nil {
		return nil, err
	}
	return decodeList[ConnectedClientSnapshot](raw, "clients")
}
func (c *ConnectedClient) Refresh(ctx context.Context) (ConnectedClientSnapshot, error) {
	input := c.route.params()
	var snapshot ConnectedClientSnapshot
	if err := c.client.readResource(ctx, wirev2.ClientGet, input, &snapshot); err != nil {
		return ConnectedClientSnapshot{}, err
	}
	return snapshot, nil
}
func (c *ConnectedClient) UpdateMetadata(ctx context.Context, options ConnectedClientMetadataUpdateOptions) (ClientSnapshot, error) {
	input := c.route.params()
	if options.Name.Present {
		input[wirev2.FieldName] = options.Name.Value
	}
	if options.Kind.Present {
		input[wirev2.FieldKind] = options.Kind.Value
	}
	merge(input, options.Extra)
	return readValue[ClientSnapshot](
		ctx, c.client, wirev2.ClientMetadataUpdate, input, "client snapshot",
	)
}
func (c *ConnectedClient) SetSizing(ctx context.Context, options ConnectedClientSizingSetOptions) (ClientSnapshot, error) {
	input := c.route.params()
	input[wirev2.FieldEnabled] = options.Enabled
	if options.Exclusive != nil {
		input["exclusive"] = *options.Exclusive
	}
	merge(input, options.Extra)
	return readValue[ClientSnapshot](
		ctx, c.client, wirev2.ClientSizingSet, input, "client snapshot",
	)
}
func (c *ConnectedClient) ReleaseSizing(ctx context.Context, options ConnectedClientSizingReleaseOptions) (ClientSnapshot, error) {
	input := c.route.params()
	merge(input, options.Extra)
	return readValue[ClientSnapshot](
		ctx, c.client, wirev2.ClientSizingRelease, input, "client snapshot",
	)
}
func (c *ConnectedClient) SetCellPixels(ctx context.Context, options ConnectedClientCellPixelsSetOptions) (CellPixelsResult, error) {
	input := c.route.params()
	input["width_px"] = options.WidthPX
	input["height_px"] = options.HeightPX
	merge(input, options.Extra)
	return readValue[CellPixelsResult](
		ctx, c.client, wirev2.ClientCellPixelsSet, input, "cell pixels result",
	)
}
func (c *ConnectedClient) Detach(ctx context.Context, options ConnectedClientDetachOptions) (EmptyResult, error) {
	input := c.route.params()
	merge(input, options.Extra)
	return readValue[EmptyResult](
		ctx, c.client, wirev2.ClientDetach, input, "empty result",
	)
}

func (s *Session) ListPairingRequests(ctx context.Context, options PairingRequestListOptions) ([]PairingRequest, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.PairingRequestList, input, "", &raw); err != nil {
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
func (p *PairingRequest) Resolve(ctx context.Context, options PairingRequestResolveOptions) (MutationResult[*PairingRequest], error) {
	input := p.route.params()
	input["decision"] = options.Decision
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PairingRequestResolve, input, options.MutationOptions,
		"pairing resolution result", p.cache, p,
	)
}
func (s *Session) Projection(ctx context.Context, options FrontendProjectionGetOptions) (*FrontendProjection, error) {
	input := s.route.withProjection(options.Projection).params()
	merge(input, options.Extra)
	var snapshot FrontendProjectionSnapshot
	if err := s.client.readResource(ctx, wirev2.ProjectionGet, input, &snapshot); err != nil {
		return nil, err
	}
	selector := SelectID(snapshot.ID)
	return &FrontendProjection{
		client: s.client, session: s.selector,
		route: s.route.withProjection(selector), snapshot: snapshot,
	}, nil
}
func (p *FrontendProjection) Put(ctx context.Context, options FrontendProjectionPutOptions) (MutationResult[*FrontendProjection], error) {
	input := p.route.params()
	input["frontend_id"] = options.FrontendID
	input["window_id"] = options.WindowID
	input["generation"] = options.Generation
	input["projection"] = options.Projection
	if options.ExpectedProjectionRevision != nil {
		input["expected_projection_revision"] = *options.ExpectedProjectionRevision
	}
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.ProjectionPut, input, options.MutationOptions,
		"frontend projection snapshot", p.cache, p,
	)
}

func (s *Session) ListWorkspaces(ctx context.Context, options WorkspaceListOptions) ([]*Workspace, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.WorkspaceList, input, "", &raw); err != nil {
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
	putOptionalString(input, wirev2.FieldName, options.Name)
	input[wirev2.FieldInitialContent] = options.InitialContent
	merge(input, options.Extra)
	return s.client.created(ctx, wirev2.WorkspaceCreate, input, options.MutationOptions)
}
func (w *Workspace) Rename(ctx context.Context, options WorkspaceRenameOptions) (MutationResult[*Workspace], error) {
	input := w.route.params()
	input[wirev2.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationHandle(
		ctx, w.client, wirev2.WorkspaceRename, input, options.MutationOptions,
		"workspace snapshot", w.cache, w,
	)
}
func (w *Workspace) Move(ctx context.Context, options WorkspaceMoveOptions) (MutationResult[*Workspace], error) {
	input := w.route.params()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationHandle(
		ctx, w.client, wirev2.WorkspaceMove, input, options.MutationOptions,
		"workspace snapshot", w.cache, w,
	)
}
func (w *Workspace) Focus(ctx context.Context, options WorkspaceFocusOptions) (MutationResult[*Workspace], error) {
	input := w.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, w.client, wirev2.WorkspaceFocus, input, options.MutationOptions,
		"workspace snapshot", w.cache, w,
	)
}
func (w *Workspace) Close(ctx context.Context, options WorkspaceCloseOptions) (MutationResult[EmptyResult], error) {
	input := w.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, w.client, wirev2.WorkspaceClose, input, options.MutationOptions,
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
	putOptionalString(input, wirev2.FieldCWD, options.CWD)
	putOptionalString(input, wirev2.FieldName, options.Name)
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return w.client.created(ctx, wirev2.WorkspaceRun, input, options.MutationOptions)
}
func (w *Workspace) ApplyLayout(ctx context.Context, options WorkspaceLayoutApplyOptions) (MutationResult[*Workspace], error) {
	input := w.route.params()
	input[wirev2.FieldLayout] = options.Layout
	merge(input, options.Extra)
	return mutationHandle(
		ctx, w.client, wirev2.WorkspaceLayoutApply, input, options.MutationOptions,
		"workspace snapshot", w.cache, w,
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
		target[wirev2.FieldArgv] = append([]string(nil), value.Argv...)
	case *ExactCommand:
		target[wirev2.FieldArgv] = append([]string(nil), value.Argv...)
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
	if err := validateRequiredJSON(raw, reflect.TypeOf(&zero), label); err != nil {
		return zero, &ProtocolError{
			Message: "cannot decode " + label + ": " + err.Error(),
		}
	}
	if err := validateDecodedValue(raw, &zero); err != nil {
		return zero, &ProtocolError{
			Message: "cannot decode " + label + ": " + err.Error(),
		}
	}
	return zero, nil
}

func validateDecodedValue(raw json.RawMessage, value any) error {
	var required []string
	switch value.(type) {
	case *MachineSnapshot:
		required = []string{
			"id", "name", "origin", "status", "connectable", "deleted",
			"recoverable",
		}
	case *SessionSnapshot:
		required = []string{
			"id", "machine_id", "generation", "revision", "connected",
		}
	case *WorkspaceSnapshot:
		required = []string{"id", "session_id", "name", "index", "focused"}
	case *ScreenSnapshot:
		required = []string{
			"id", "workspace_id", "name", "index", "focused", "layout",
		}
	case *PaneSnapshot:
		required = []string{"id", "screen_id", "name", "focused", "zoomed"}
	case *TabSnapshot:
		required = []string{
			"id", "pane_id", "name", "index", "focused", "content_kind",
			"content_id",
		}
	case *TerminalSnapshot:
		required = []string{
			"id", "title", "cols", "rows", "running", "lifecycle",
		}
	case *BrowserSnapshot:
		required = []string{
			"id", "tab_id", "url", "title", "loading", "source", "status",
			"error", "frames_stalled", "size",
		}
	case *ConnectedClientSnapshot:
		required = []string{
			"id", "session_id", "name", "client_kind", "transport",
			"connected_seconds", "attached_terminal_ids", "sizes", "self",
		}
	case *NotificationSnapshot:
		required = []string{
			"id", "session_id", "title", "body", "level", "created_at_ms",
			"unread",
		}
	case *AgentSnapshot:
		required = []string{
			"id", "session_id", "terminal_id", "state", "source",
			"updated_at_ms", "source_session",
		}
	case *PairingRequestSnapshot:
		required = []string{
			"id", "session_id", "peer", "code", "expires_in_seconds", "status",
		}
	case *FrontendProjectionSnapshot:
		required = []string{
			"id", "session_id", "frontend_id", "window_id", "generation",
			"projection", "projection_revision",
		}
	case *SidebarViewSnapshot:
		required = []string{"id", "session_id", "cols", "rows", "running"}
	case *PingResult:
		required = []string{"alive", "cursor"}
	case *ShutdownResult:
		required = []string{"accepted"}
	case *ReloadConfigResult:
		required = []string{"reloaded", "warnings"}
	case *PairingResolutionResult:
		required = []string{"pairing_request"}
	case *TerminalScreenResult:
		required = []string{
			"text", "cols", "rows", "cursor_row", "cursor_col", "cursor_visible",
		}
	case *TerminalStateResult:
		required = []string{"state_base64", "cols", "rows"}
	case *TerminalHistoryResult:
		required = []string{"start", "rows"}
	case *TerminalWaitResult:
		required = []string{"matched", "text"}
	case *TerminalCopyResult:
		required = []string{"mode", "text"}
	case *ProcessInfoResult:
		required = []string{"pid", "argv", "children"}
	case *CellPixelsResult:
		required = []string{
			"width_px", "height_px", "resized_terminals", "failures",
		}
	case *ViewerResizeResult, *BrowserViewerResizeResult:
		required = []string{"accepted", "size", "outcome"}
	case *ViewerReleaseResult:
		required = []string{"outcome"}
	case *ViewAttachmentStreamOpened:
		required = []string{"stream_id", "attachment_lease"}
	case *RenderCursor:
		required = []string{"x", "y", "style", "blink", "visible", "color"}
	case *RenderRun:
		required = []string{"text", "fg", "bg", "attrs"}
	case *RenderRow:
		required = []string{"row", "runs"}
	case *RenderSnapshot:
		required = []string{
			"size", "cursor", "default_fg", "default_bg", "scrollback_rows", "rows",
		}
	case *RenderPatch:
		required = []string{"cursor", "full_reset", "rows"}
	case *RenderScroll:
		required = []string{"offset", "at_bottom"}
	case *ResourceSnapshot:
		required = []string{
			"machine", "session", "workspaces", "screens", "panes", "tabs",
			"terminals", "browsers", "clients", "notifications", "agents",
			"frontend_projections", "sidebar_views", "cursor",
		}
	}
	if len(required) > 0 {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &fields); err != nil {
			return err
		}
		for _, field := range required {
			if _, ok := fields[field]; !ok {
				return fmt.Errorf("omitted required field %s", field)
			}
		}
	}

	switch decoded := value.(type) {
	case *MachineSnapshot:
		if decoded.ID == "" {
			return fmt.Errorf("machine snapshot id must be present")
		}
		switch decoded.Origin {
		case "local":
		default:
			return fmt.Errorf("invalid machine origin %q", decoded.Origin)
		}
		switch decoded.Status {
		case "running", "connecting", "sleeping", "stopped", "unavailable":
		default:
			return fmt.Errorf("invalid machine status %q", decoded.Status)
		}
	case *SessionSnapshot:
		if decoded.ID == "" || decoded.MachineID == "" || decoded.Generation == "" {
			return fmt.Errorf("session snapshot ids and generation must be present")
		}
	case *WorkspaceSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" {
			return fmt.Errorf("workspace snapshot ids must be present")
		}
	case *ScreenSnapshot:
		if decoded.ID == "" || decoded.WorkspaceID == "" ||
			decoded.Layout.Root == nil {
			return fmt.Errorf("screen snapshot ids and layout must be present")
		}
	case *PaneSnapshot:
		if decoded.ID == "" || decoded.ScreenID == "" {
			return fmt.Errorf("pane snapshot ids must be present")
		}
	case *TabSnapshot:
		if decoded.ID == "" || decoded.PaneID == "" || decoded.ContentID == nil {
			return fmt.Errorf("tab snapshot ids must be present")
		}
	case *TerminalSnapshot:
		if decoded.ID == "" || decoded.TabIDs == nil ||
			decoded.Cols == 0 || decoded.Rows == 0 {
			return fmt.Errorf("terminal snapshot ids and dimensions must be present")
		}
		switch decoded.Lifecycle {
		case TerminalLifecycleLaunching, TerminalLifecycleRunning,
			TerminalLifecycleExited:
		default:
			return fmt.Errorf(
				"terminal snapshot has invalid lifecycle %q",
				decoded.Lifecycle,
			)
		}
		if decoded.Running != (decoded.Lifecycle == TerminalLifecycleRunning) {
			return fmt.Errorf(
				"terminal running must be true exactly while lifecycle is running",
			)
		}
		var terminalFields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &terminalFields); err != nil {
			return err
		}
		exitRaw, hasExit := terminalFields["exit"]
		if hasExit && bytes.Equal(bytes.TrimSpace(exitRaw), []byte("null")) {
			return fmt.Errorf("terminal exit cannot be null")
		}
		if hasExit != (decoded.Lifecycle == TerminalLifecycleExited) ||
			hasExit != (decoded.Exit != nil) {
			return fmt.Errorf(
				"terminal exit must be present exactly while lifecycle is exited",
			)
		}
	case *BrowserSnapshot:
		if decoded.ID == "" || decoded.TabID == "" ||
			decoded.Size.Cols == 0 || decoded.Size.Rows == 0 {
			return fmt.Errorf("browser snapshot ids and size must be present")
		}
		switch decoded.Source {
		case "external", "launched":
		default:
			return fmt.Errorf("invalid browser source %q", decoded.Source)
		}
		switch decoded.Status {
		case "starting", "live", "failed":
		default:
			return fmt.Errorf("invalid browser status %q", decoded.Status)
		}
		if decoded.Loading != (decoded.Status == "starting") {
			return fmt.Errorf("browser loading must be true exactly while status is starting")
		}
		if (decoded.Error != nil) != (decoded.Status == "failed") {
			return fmt.Errorf("browser error must be non-null exactly while status is failed")
		}
	case *ConnectedClientSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" ||
			decoded.AttachedTerminalIDs == nil || decoded.Sizes == nil {
			return fmt.Errorf("client snapshot ids and arrays must be present")
		}
		switch decoded.Transport {
		case "unix", "websocket":
		default:
			return fmt.Errorf("invalid client transport %q", decoded.Transport)
		}
		for index, size := range decoded.Sizes {
			if size.TerminalID == "" {
				return fmt.Errorf("client size %d omitted terminal_id", index)
			}
			if (size.Cols == nil) != (size.Rows == nil) {
				return fmt.Errorf("client size %d must pair cols and rows", index)
			}
			if size.Cols != nil && (*size.Cols == 0 || *size.Rows == 0) {
				return fmt.Errorf("client size %d dimensions must be non-zero", index)
			}
		}
	case *NotificationSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" {
			return fmt.Errorf("notification snapshot ids must be present")
		}
		switch decoded.Level {
		case "info", "warning", "error":
		default:
			return fmt.Errorf("invalid notification level %q", decoded.Level)
		}
	case *AgentSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" || decoded.TerminalID == "" {
			return fmt.Errorf("agent snapshot ids must be present")
		}
		switch decoded.State {
		case "working", "blocked", "idle", "done", "unknown":
		default:
			return fmt.Errorf("invalid agent state %q", decoded.State)
		}
		switch decoded.Source {
		case "hook", "socket", "detected":
		default:
			return fmt.Errorf("invalid agent source %q", decoded.Source)
		}
	case *PairingRequestSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" {
			return fmt.Errorf("pairing request snapshot ids must be present")
		}
		switch decoded.Status {
		case "pending", "accepted", "rejected":
		default:
			return fmt.Errorf("invalid pairing request status %q", decoded.Status)
		}
	case *FrontendProjectionSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" || decoded.FrontendID == "" ||
			decoded.WindowID == "" || decoded.Generation == "" {
			return fmt.Errorf("frontend projection snapshot ids must be present")
		}
	case *SidebarViewSnapshot:
		if decoded.ID == "" || decoded.SessionID == "" ||
			decoded.Cols == 0 || decoded.Rows == 0 {
			return fmt.Errorf("sidebar view snapshot ids and size must be present")
		}
	case *PingResult:
		if decoded.Cursor.Generation == "" {
			return fmt.Errorf("ping cursor generation must be non-empty")
		}
	case *ReloadConfigResult:
		if decoded.Warnings == nil {
			return fmt.Errorf("reload config warnings must be present")
		}
	case *TerminalDefaultsSnapshot:
		for name, color := range map[string]*string{
			"foreground":           decoded.Foreground,
			"background":           decoded.Background,
			"cursor":               decoded.Cursor,
			"selection_background": decoded.SelectionBackground,
			"selection_foreground": decoded.SelectionForeground,
		} {
			if color != nil && !validColor(*color) {
				return fmt.Errorf("%s must be #rrggbb", name)
			}
		}
		if decoded.CursorStyle != nil {
			switch *decoded.CursorStyle {
			case "block", "bar", "underline":
			default:
				return fmt.Errorf("invalid terminal cursor style %q", *decoded.CursorStyle)
			}
		}
	case *TerminalScreenResult:
		if decoded.Cols == 0 || decoded.Rows == 0 {
			return fmt.Errorf("terminal screen dimensions must be non-zero")
		}
	case *TerminalStateResult:
		if decoded.Cols == 0 || decoded.Rows == 0 {
			return fmt.Errorf("terminal state dimensions must be non-zero")
		}
	case *TerminalHistoryResult:
		return validateRenderRows(decoded.Rows)
	case *TerminalCopyResult:
		switch decoded.Mode {
		case "screen", "selection", "scrollback":
		default:
			return fmt.Errorf("invalid terminal copy mode %q", decoded.Mode)
		}
	case *ProcessInfoResult:
		if decoded.Argv == nil || decoded.Children == nil {
			return fmt.Errorf("process argv and children must be present")
		}
	case *CellPixelsResult:
		if decoded.WidthPX == 0 || decoded.HeightPX == 0 ||
			decoded.ResizedTerminals == nil || decoded.Failures == nil {
			return fmt.Errorf("cell pixel result has missing or zero fields")
		}
	case *ViewerResizeResult:
		if decoded.Size.Cols == 0 || decoded.Size.Rows == 0 {
			return fmt.Errorf("viewer resize size must be non-zero")
		}
		return validateViewAttachmentOutcome(decoded.Outcome)
	case *BrowserViewerResizeResult:
		if decoded.Size.WidthPX == 0 || decoded.Size.HeightPX == 0 {
			return fmt.Errorf("browser viewer resize size must be non-zero")
		}
		return validateViewAttachmentOutcome(decoded.Outcome)
	case *ViewerReleaseResult:
		return validateViewAttachmentOutcome(decoded.Outcome)
	case *RenderCursor:
		return validateRenderCursor(*decoded)
	case *RenderRun:
		return validateRenderRows([]RenderRow{{Runs: []RenderRun{*decoded}}})
	case *RenderRow:
		return validateRenderRows([]RenderRow{*decoded})
	case *RenderSnapshot:
		return validateRenderSnapshot(*decoded)
	case *RenderPatch:
		return validateRenderPatch(*decoded)
	case *ResourceSnapshot:
		if decoded.Cursor.Generation == "" {
			return fmt.Errorf("resource snapshot cursor generation must be non-empty")
		}
	}
	return nil
}

func (w *Workspace) ListScreens(ctx context.Context, options ScreenListOptions) ([]*Screen, error) {
	input := w.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := w.client.do(ctx, wirev2.ScreenList, input, "", &raw); err != nil {
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
	putOptionalString(input, wirev2.FieldName, options.Name)
	merge(input, options.Extra)
	return w.client.created(ctx, wirev2.ScreenCreate, input, options.MutationOptions)
}
func (s *Screen) Rename(ctx context.Context, options ScreenRenameOptions) (MutationResult[*Screen], error) {
	input := s.route.params()
	input[wirev2.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationHandle(
		ctx, s.client, wirev2.ScreenRename, input, options.MutationOptions,
		"screen snapshot", s.cache, s,
	)
}
func (s *Screen) Focus(ctx context.Context, options ScreenFocusOptions) (MutationResult[*Screen], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, s.client, wirev2.ScreenFocus, input, options.MutationOptions,
		"screen snapshot", s.cache, s,
	)
}
func (s *Screen) Close(ctx context.Context, options ScreenCloseOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev2.ScreenClose, input, options.MutationOptions,
		"empty result",
	)
}
func (s *Screen) ExportLayout(ctx context.Context, options ScreenLayoutExportOptions) (LayoutDocument, error) {
	input := s.route.params()
	merge(input, options.Extra)
	return readValue[LayoutDocument](
		ctx, s.client, wirev2.ScreenLayoutExport, input, "layout document",
	)
}
func (s *Screen) UndoLayout(ctx context.Context, options ScreenLayoutUndoOptions) (MutationResult[*Screen], error) {
	if options.ConfirmationToken != nil &&
		(len(*options.ConfirmationToken) < 1 || len(*options.ConfirmationToken) > 128) {
		return MutationResult[*Screen]{}, fmt.Errorf(
			"%w: confirmation token must contain 1 to 128 characters",
			ErrInvalidArgument,
		)
	}
	if options.ConfirmClose && options.ConfirmationToken == nil {
		return MutationResult[*Screen]{}, fmt.Errorf(
			"%w: ConfirmClose requires ConfirmationToken",
			ErrInvalidArgument,
		)
	}
	input := s.route.params()
	if options.ConfirmClose {
		input["confirm_close"] = true
	}
	putOptionalString(input, "confirmation_token", options.ConfirmationToken)
	merge(input, options.Extra)
	return mutationHandle(
		ctx, s.client, wirev2.ScreenLayoutUndo, input, options.MutationOptions,
		"screen snapshot", s.cache, s,
	)
}

func (s *Screen) ListPanes(ctx context.Context, options PaneListOptions) ([]*Pane, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.PaneList, input, "", &raw); err != nil {
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
	putOptionalString(input, wirev2.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return s.client.created(ctx, wirev2.PaneCreate, input, options.MutationOptions)
}
func (p *Pane) Split(ctx context.Context, options PaneSplitOptions) (MutationResult[CreatedPath], error) {
	input := p.route.params()
	input[wirev2.FieldDirection] = options.Direction
	if options.Ratio != nil {
		input[wirev2.FieldRatio] = *options.Ratio
	}
	if options.ViewportWidth != nil {
		input[wirev2.FieldViewportWidth] = *options.ViewportWidth
	}
	putOptionalString(input, wirev2.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev2.PaneSplit, input, options.MutationOptions)
}
func (p *Pane) Rename(ctx context.Context, options PaneRenameOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	input[wirev2.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneRename, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) Focus(ctx context.Context, options PaneFocusOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneFocus, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) FocusDirection(ctx context.Context, options PaneFocusDirectionOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	input[wirev2.FieldDirection] = options.Direction
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneFocusDirection, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) Neighbor(ctx context.Context, options PaneNeighborGetOptions) (*Pane, error) {
	input := p.route.params()
	input[wirev2.FieldDirection] = options.Direction
	merge(input, options.Extra)
	result, err := readValue[PaneNeighborResult](
		ctx,
		p.client,
		wirev2.PaneNeighborGet,
		input,
		"pane neighbor result",
	)
	if err != nil {
		return nil, err
	}
	if result.Pane == nil {
		return nil, nil
	}
	snapshot := *result.Pane
	selector := SelectID(snapshot.ID)
	return &Pane{
		client: p.client, screen: p.screen, selector: selector,
		route: p.route.withPane(selector), snapshot: &snapshot,
	}, nil
}
func (p *Pane) Swap(ctx context.Context, options PaneSwapOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	input["other_workspace"] = options.OtherWorkspace.String()
	input["other_screen"] = options.OtherScreen.String()
	input["other_pane"] = options.OtherPane.String()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneSwap, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) Zoom(ctx context.Context, options PaneZoomOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	if options.Enabled != nil {
		input[wirev2.FieldEnabled] = *options.Enabled
	}
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneZoom, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) SetSplitRatio(ctx context.Context, options PaneSplitRatioSetOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	input["split_id"] = options.SplitID
	input[wirev2.FieldRatio] = options.Ratio
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneSplitRatioSet, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) SetViewportWidth(ctx context.Context, options PaneViewportWidthSetOptions) (MutationResult[*Pane], error) {
	input := p.route.params()
	input["columns"] = options.Columns
	merge(input, options.Extra)
	return mutationHandle(
		ctx, p.client, wirev2.PaneViewportWidthSet, input, options.MutationOptions,
		"pane snapshot", p.cache, p,
	)
}
func (p *Pane) Close(ctx context.Context, options PaneCloseOptions) (MutationResult[EmptyResult], error) {
	input := p.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, p.client, wirev2.PaneClose, input, options.MutationOptions,
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
	putOptionalString(input, wirev2.FieldCWD, options.CWD)
	putOptionalString(input, wirev2.FieldName, options.Name)
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev2.PaneRun, input, options.MutationOptions)
}

func (p *Pane) ListTabs(ctx context.Context, options TabListOptions) ([]*Tab, error) {
	input := p.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := p.client.do(ctx, wirev2.TabList, input, "", &raw); err != nil {
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
	putOptionalString(input, wirev2.FieldName, options.Name)
	putOptionalString(input, wirev2.FieldCWD, options.CWD)
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev2.TabCreateTerminal, input, options.MutationOptions)
}
func (p *Pane) CreateBrowserTab(ctx context.Context, options TabCreateBrowserOptions) (MutationResult[CreatedPath], error) {
	input := p.route.params()
	putOptionalString(input, wirev2.FieldName, options.Name)
	input[wirev2.FieldURL] = options.URL
	if options.WidthPX != nil {
		input["width_px"] = *options.WidthPX
	}
	if options.HeightPX != nil {
		input["height_px"] = *options.HeightPX
	}
	merge(input, options.Extra)
	return p.client.created(ctx, wirev2.TabCreateBrowser, input, options.MutationOptions)
}
func (t *Tab) Rename(ctx context.Context, options TabRenameOptions) (MutationResult[*Tab], error) {
	input := t.route.params()
	input[wirev2.FieldName] = options.Name
	merge(input, options.Extra)
	return mutationHandle(
		ctx, t.client, wirev2.TabRename, input, options.MutationOptions,
		"tab snapshot", t.cache, t,
	)
}
func (t *Tab) Move(ctx context.Context, options TabMoveOptions) (MutationResult[*Tab], error) {
	input := t.route.params()
	input["destination_workspace"] = options.DestinationWorkspace.String()
	input["destination_screen"] = options.DestinationScreen.String()
	input["destination_pane"] = options.DestinationPane.String()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationHandle(
		ctx, t.client, wirev2.TabMove, input, options.MutationOptions,
		"tab snapshot", t.cache, t,
	)
}
func (t *Tab) Focus(ctx context.Context, options TabFocusOptions) (MutationResult[*Tab], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, t.client, wirev2.TabFocus, input, options.MutationOptions,
		"tab snapshot", t.cache, t,
	)
}
func (t *Tab) Close(ctx context.Context, options TabCloseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TabClose, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListTerminals(ctx context.Context, options TerminalListOptions) ([]*Terminal, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.TerminalList, input, "", &raw); err != nil {
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
		input[wirev2.FieldText] = *options.Text
	} else {
		input["bytes_base64"] = base64.StdEncoding.EncodeToString(options.Bytes)
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalInputWrite, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Keys(ctx context.Context, options TerminalInputKeysOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev2.FieldKeys] = options.Keys
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalInputKeys, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Mouse(ctx context.Context, options TerminalInputMouseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev2.FieldKind] = options.Kind
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
		ctx, t.client, wirev2.TerminalInputMouse, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) FocusInput(ctx context.Context, options TerminalInputFocusOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input[wirev2.FieldFocused] = options.Focused
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalInputFocus, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) ReadScreen(ctx context.Context, options TerminalScreenReadOptions) (TerminalScreenResult, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return readValue[TerminalScreenResult](
		ctx, t.client, wirev2.TerminalScreenRead, input, "terminal screen result",
	)
}
func (t *Terminal) ReadState(ctx context.Context, options TerminalStateReadOptions) (TerminalStateResult, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return readValue[TerminalStateResult](
		ctx, t.client, wirev2.TerminalStateRead, input, "terminal state result",
	)
}
func (t *Terminal) ReadHistory(ctx context.Context, options TerminalHistoryReadOptions) (TerminalHistoryResult, error) {
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
	return readValue[TerminalHistoryResult](
		ctx, t.client, wirev2.TerminalHistoryRead, input, "terminal history result",
	)
}
func (t *Terminal) ClearHistory(ctx context.Context, options TerminalHistoryClearOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalHistoryClear, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Wait(ctx context.Context, options TerminalWaitOptions) (TerminalWaitResult, error) {
	input := t.route.params()
	input["pattern"] = options.Pattern
	if options.TimeoutMS != nil {
		input[wirev2.FieldTimeoutMS] = *options.TimeoutMS
	}
	merge(input, options.Extra)
	return readValue[TerminalWaitResult](
		ctx, t.client, wirev2.TerminalWait, input, "terminal wait result",
	)
}
func (t *Terminal) WaitExit(
	ctx context.Context,
	options TerminalWaitExitOptions,
) (TerminalWaitExitResult, error) {
	input := t.route.params()
	if options.TimeoutMS != nil {
		input[wirev2.FieldTimeoutMS] = *options.TimeoutMS
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := t.client.do(
		ctx,
		wirev2.TerminalWaitExit,
		input,
		"",
		&raw,
	); err != nil {
		return nil, err
	}
	result, err := decodeTerminalWaitExitResult(raw)
	if err != nil {
		return nil, &ProtocolError{
			Message: "cannot decode terminal wait exit result: " + err.Error(),
		}
	}
	var expected TerminalID
	var hasExpected bool
	if snapshot, ok := t.Cached(); ok {
		expected, hasExpected = snapshot.ID, true
	} else {
		expected, hasExpected = t.selector.ID()
	}
	var actual TerminalID
	switch value := result.(type) {
	case TerminalWaitExitPending:
		actual = value.TerminalID
	case TerminalWaitExitExited:
		actual = value.TerminalID
	default:
		return nil, &ProtocolError{
			Message: fmt.Sprintf(
				"terminal wait exit decoder returned unsupported %T",
				result,
			),
		}
	}
	if hasExpected && actual != expected {
		return nil, &ProtocolError{
			Message: fmt.Sprintf(
				"terminal wait_exit returned %s for %s",
				actual,
				expected,
			),
		}
	}
	return result, nil
}
func (t *Terminal) Copy(ctx context.Context, options TerminalCopyOptions) (TerminalCopyResult, error) {
	input := t.route.params()
	if options.Mode != nil {
		input[wirev2.FieldMode] = *options.Mode
	}
	merge(input, options.Extra)
	return readValue[TerminalCopyResult](
		ctx, t.client, wirev2.TerminalCopy, input, "terminal copy result",
	)
}
func (t *Terminal) Process(ctx context.Context, options TerminalProcessGetOptions) (ProcessInfoResult, error) {
	input := t.route.params()
	merge(input, options.Extra)
	return readValue[ProcessInfoResult](
		ctx, t.client, wirev2.TerminalProcessGet, input, "process info result",
	)
}
func (t *Terminal) CreateRendererGrant(ctx context.Context, options TerminalRendererGrantCreateOptions) (RendererGrant, error) {
	input := t.route.params()
	if options.TTLMS != nil {
		input["ttl_ms"] = *options.TTLMS
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := t.client.do(ctx, wirev2.TerminalRendererGrantCreate, input, "", &raw); err != nil {
		return RendererGrant{}, err
	}
	return decodeRendererGrant(raw)
}
func (t *Terminal) ResizeViewer(ctx context.Context, options TerminalViewerResizeOptions) (ViewerResizeResult, error) {
	input := t.route.params()
	input["attachment_lease"] = options.AttachmentLease
	input[wirev2.FieldCols] = options.Cols
	input[wirev2.FieldRows] = options.Rows
	merge(input, options.Extra)
	return readValue[ViewerResizeResult](
		ctx, t.client, wirev2.TerminalViewerResize, input, "viewer resize result",
	)
}
func (t *Terminal) ReleaseViewer(ctx context.Context, options TerminalViewerReleaseOptions) (ViewerReleaseResult, error) {
	input := t.route.params()
	input["attachment_lease"] = options.AttachmentLease
	merge(input, options.Extra)
	return readValue[ViewerReleaseResult](
		ctx, t.client, wirev2.TerminalViewerRelease, input, "viewer release result",
	)
}
func (t *Terminal) ScrollViewport(ctx context.Context, options TerminalViewportScrollOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	input["delta_rows"] = options.DeltaRows
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalViewportScroll, input, options.MutationOptions,
		"empty result",
	)
}
func (t *Terminal) Move(ctx context.Context, options TerminalMoveOptions) (MutationResult[*Terminal], error) {
	input := t.route.params()
	input["destination_workspace"] = options.DestinationWorkspace.String()
	input["destination_screen"] = options.DestinationScreen.String()
	input["destination_pane"] = options.DestinationPane.String()
	input["index"] = options.Index
	merge(input, options.Extra)
	return mutationHandle(
		ctx, t.client, wirev2.TerminalMove, input, options.MutationOptions,
		"terminal snapshot", t.cache, t,
	)
}
func (t *Terminal) Project(ctx context.Context, options TerminalProjectOptions) (MutationResult[*Tab], error) {
	input := t.route.params()
	input["destination_workspace"] = options.DestinationWorkspace.String()
	input["destination_screen"] = options.DestinationScreen.String()
	input["destination_pane"] = options.DestinationPane.String()
	input["index"] = options.Index
	if options.Name != nil {
		input["name"] = *options.Name
	}
	merge(input, options.Extra)
	return mutationNewHandle(
		ctx, t.client, wirev2.TerminalProject, input, options.MutationOptions,
		"tab snapshot", func(snapshot TabSnapshot) *Tab {
			selector := SelectID(snapshot.ID)
			route := t.route
			route.workspace = options.DestinationWorkspace
			route.screen = options.DestinationScreen
			route.pane = options.DestinationPane
			route.tab = selector
			route.terminal = Selector[TerminalID]{}
			return &Tab{
				client: t.client, pane: options.DestinationPane, selector: selector,
				route: route, snapshot: &snapshot,
			}
		},
	)
}
func (t *Terminal) Attach(ctx context.Context, options TerminalAttachOptions) (*Stream[TerminalAttachmentItem], error) {
	input := t.route.params()
	if options.Cols != nil {
		input[wirev2.FieldCols] = *options.Cols
	}
	if options.Rows != nil {
		input[wirev2.FieldRows] = *options.Rows
	}
	if options.ReadOnly != nil {
		input["read_only"] = *options.ReadOnly
	}
	merge(input, options.Extra)
	return openStream(ctx, t.client, wirev2.TerminalAttach, input, decodeTerminalAttachment)
}
func (t *Terminal) Close(ctx context.Context, options TerminalCloseOptions) (MutationResult[EmptyResult], error) {
	input := t.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, t.client, wirev2.TerminalClose, input, options.MutationOptions,
		"empty result",
	)
}

func (s *Session) ListBrowsers(ctx context.Context, options BrowserListOptions) ([]*Browser, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.BrowserList, input, "", &raw); err != nil {
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
func (b *Browser) Navigate(ctx context.Context, options BrowserNavigateOptions) (MutationResult[*Browser], error) {
	input := b.route.params()
	input[wirev2.FieldURL] = options.URL
	merge(input, options.Extra)
	return mutationHandle(
		ctx, b.client, wirev2.BrowserNavigate, input, options.MutationOptions,
		"browser snapshot", b.cache, b,
	)
}
func (b *Browser) Back(ctx context.Context, options BrowserBackOptions) (MutationResult[*Browser], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, b.client, wirev2.BrowserBack, input, options.MutationOptions,
		"browser snapshot", b.cache, b,
	)
}
func (b *Browser) Forward(ctx context.Context, options BrowserForwardOptions) (MutationResult[*Browser], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, b.client, wirev2.BrowserForward, input, options.MutationOptions,
		"browser snapshot", b.cache, b,
	)
}
func (b *Browser) Reload(ctx context.Context, options BrowserReloadOptions) (MutationResult[*Browser], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, b.client, wirev2.BrowserReload, input, options.MutationOptions,
		"browser snapshot", b.cache, b,
	)
}
func (b *Browser) Activate(ctx context.Context, options BrowserActivateOptions) (MutationResult[*Browser], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, b.client, wirev2.BrowserActivate, input, options.MutationOptions,
		"browser snapshot", b.cache, b,
	)
}
func (b *Browser) Key(ctx context.Context, options BrowserInputKeyOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input["key"] = options.Key
	if options.Kind != nil {
		input[wirev2.FieldKind] = *options.Kind
	}
	if options.Modifiers != nil {
		input["modifiers"] = options.Modifiers
	}
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev2.BrowserInputKey, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Text(ctx context.Context, options BrowserInputTextOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input[wirev2.FieldText] = options.Text
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev2.BrowserInputText, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Mouse(ctx context.Context, options BrowserInputMouseOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input[wirev2.FieldKind] = options.Kind
	input["x_px"] = options.XPX
	input["y_px"] = options.YPX
	if options.Button != nil {
		input["button"] = *options.Button
	}
	if options.ClickCount != nil {
		input["click_count"] = *options.ClickCount
	}
	input[wirev2.FieldPointerFrameSeq] = options.PointerFrameSeq
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev2.BrowserInputMouse, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) Wheel(ctx context.Context, options BrowserInputWheelOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	input["delta_x"] = options.DeltaX
	input["delta_y"] = options.DeltaY
	input["x_px"] = options.XPX
	input["y_px"] = options.YPX
	input[wirev2.FieldPointerFrameSeq] = options.PointerFrameSeq
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev2.BrowserInputWheel, input, options.MutationOptions,
		"empty result",
	)
}
func (b *Browser) ResizeViewer(ctx context.Context, options BrowserViewerResizeOptions) (BrowserViewerResizeResult, error) {
	input := b.route.params()
	input["attachment_lease"] = options.AttachmentLease
	input["width_px"] = options.WidthPX
	input["height_px"] = options.HeightPX
	merge(input, options.Extra)
	return readValue[BrowserViewerResizeResult](
		ctx, b.client, wirev2.BrowserViewerResize, input,
		"browser viewer resize result",
	)
}
func (b *Browser) ReleaseViewer(ctx context.Context, options BrowserViewerReleaseOptions) (ViewerReleaseResult, error) {
	input := b.route.params()
	input["attachment_lease"] = options.AttachmentLease
	merge(input, options.Extra)
	return readValue[ViewerReleaseResult](
		ctx, b.client, wirev2.BrowserViewerRelease, input, "viewer release result",
	)
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
	return openStream(ctx, b.client, wirev2.BrowserAttach, input, decodeBrowserAttachment)
}
func (b *Browser) Close(ctx context.Context, options BrowserCloseOptions) (MutationResult[EmptyResult], error) {
	input := b.route.params()
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, b.client, wirev2.BrowserClose, input, options.MutationOptions,
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
	if err := s.client.do(ctx, wirev2.NotificationList, input, "", &raw); err != nil {
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
	input[wirev2.FieldTitle] = options.Title
	input[wirev2.FieldBody] = options.Body
	if options.Level != nil {
		input[wirev2.FieldLevel] = *options.Level
	}
	if options.TerminalID != nil {
		input["terminal_id"] = *options.TerminalID
	}
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := s.client.mutationRaw(ctx, wirev2.NotificationCreate, input, options.IdempotencyKey)
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
	if options.State != nil && !validAgentState(*options.State) {
		return nil, fmt.Errorf(
			"%w: unsupported agent state %q",
			ErrInvalidArgument,
			*options.State,
		)
	}
	input := s.route.params()
	if options.TerminalID != nil {
		input["terminal_id"] = *options.TerminalID
	}
	if options.State != nil {
		input[wirev2.FieldState] = *options.State
	}
	merge(input, options.Extra)
	var raw json.RawMessage
	if err := s.client.do(ctx, wirev2.AgentList, input, "", &raw); err != nil {
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
func (s *Session) ReportAgent(ctx context.Context, options AgentReportOptions) (MutationResult[*Agent], error) {
	if options.TerminalID == "" {
		return MutationResult[*Agent]{}, fmt.Errorf(
			"%w: terminal ID must not be empty",
			ErrInvalidArgument,
		)
	}
	if !validAgentState(options.State) {
		return MutationResult[*Agent]{}, fmt.Errorf(
			"%w: unsupported agent state %q",
			ErrInvalidArgument,
			options.State,
		)
	}
	if options.Source != AgentReportSourceHook &&
		options.Source != AgentReportSourceSocket {
		return MutationResult[*Agent]{}, fmt.Errorf(
			"%w: unsupported agent report source %q",
			ErrInvalidArgument,
			options.Source,
		)
	}
	input := s.route.params()
	input["terminal_id"] = options.TerminalID
	input[wirev2.FieldState] = options.State
	input["source"] = options.Source
	if options.SourceSession != nil {
		input["source_session"] = *options.SourceSession
	}
	merge(input, options.Extra)
	result, err := mutationValue[AgentSnapshot](
		ctx,
		s.client,
		wirev2.AgentReport,
		input,
		options.MutationOptions,
		"agent snapshot",
	)
	if err != nil {
		return MutationResult[*Agent]{}, err
	}
	agent := &Agent{
		client: s.client, session: s.selector, route: s.route,
		snapshot: result.Value,
	}
	return MutationResult[*Agent]{
		Value: agent, Generation: result.Generation, Revision: result.Revision,
		Replayed: result.Replayed,
	}, nil
}

func validAgentState(state AgentState) bool {
	switch state {
	case AgentStateWorking,
		AgentStateBlocked,
		AgentStateIdle,
		AgentStateDone,
		AgentStateUnknown:
		return true
	default:
		return false
	}
}

func (s *SidebarView) Refresh(ctx context.Context, options SidebarViewGetOptions) (SidebarViewSnapshot, error) {
	input := s.route.params()
	merge(input, options.Extra)
	var snapshot SidebarViewSnapshot
	if err := s.client.readResource(ctx, wirev2.SidebarViewGet, input, &snapshot); err != nil {
		return SidebarViewSnapshot{}, err
	}
	if err := s.cache(snapshot); err != nil {
		return SidebarViewSnapshot{}, err
	}
	return snapshot, nil
}
func (s *Session) EnsureSidebarView(ctx context.Context, options SidebarViewEnsureOptions) (MutationResult[*SidebarView], error) {
	input := s.route.params()
	input[wirev2.FieldCols] = options.Cols
	input[wirev2.FieldRows] = options.Rows
	if options.Relaunch != nil {
		input["relaunch"] = *options.Relaunch
	}
	merge(input, options.Extra)
	putExpectedRevision(input, options.MutationOptions)
	raw, err := s.client.mutationRaw(ctx, wirev2.SidebarViewEnsure, input, options.IdempotencyKey)
	if err != nil {
		return MutationResult[*SidebarView]{}, err
	}
	snapshot, err := decodeValue[SidebarViewSnapshot](raw.value, "sidebar view")
	if err != nil {
		return MutationResult[*SidebarView]{}, err
	}
	value := &SidebarView{
		client: s.client, session: s.selector, selector: SelectID(snapshot.ID),
		route:    s.route.withSidebarView(SelectID(snapshot.ID)),
		snapshot: &snapshot,
	}
	return MutationResult[*SidebarView]{
		Value: value, Generation: raw.generation, Revision: raw.revision,
		Replayed: raw.replayed,
	}, nil
}
func (s *SidebarView) Attach(ctx context.Context, options SidebarViewAttachOptions) (*Stream[SidebarViewItem], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return openStream(ctx, s.client, wirev2.SidebarViewAttach, input, decodeSidebarViewItem)
}
func (s *SidebarView) Input(ctx context.Context, options SidebarViewInputOptions) (MutationResult[EmptyResult], error) {
	input := s.route.params()
	input["data_base64"] = base64.StdEncoding.EncodeToString(options.Data)
	merge(input, options.Extra)
	return mutationValue[EmptyResult](
		ctx, s.client, wirev2.SidebarViewInput, input, options.MutationOptions,
		"empty result",
	)
}
func (s *SidebarView) Resize(ctx context.Context, options SidebarViewResizeOptions) (MutationResult[*SidebarView], error) {
	input := s.route.params()
	input[wirev2.FieldCols] = options.Cols
	input[wirev2.FieldRows] = options.Rows
	merge(input, options.Extra)
	return mutationHandle(
		ctx, s.client, wirev2.SidebarViewResize, input, options.MutationOptions,
		"sidebar view snapshot", s.cache, s,
	)
}
func (s *SidebarView) Reload(ctx context.Context, options SidebarViewReloadOptions) (MutationResult[*SidebarView], error) {
	input := s.route.params()
	merge(input, options.Extra)
	return mutationHandle(
		ctx, s.client, wirev2.SidebarViewReload, input, options.MutationOptions,
		"sidebar view snapshot", s.cache, s,
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
			Kind        string          `json:"kind"`
			Cursor      *Cursor         `json:"cursor"`
			ResetReason *string         `json:"reset_reason,omitempty"`
			Snapshot    json.RawMessage `json:"snapshot"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SessionEvent{}, &ProtocolError{Message: "invalid session snapshot item: " + err.Error()}
		}
		if known.Cursor == nil || len(known.Snapshot) == 0 {
			return SessionEvent{}, &ProtocolError{Message: "session snapshot item requires cursor and snapshot"}
		}
		if known.ResetReason != nil &&
			*known.ResetReason != "initial" &&
			*known.ResetReason != "generation_changed" &&
			*known.ResetReason != "cursor_expired" {
			return SessionEvent{}, &ProtocolError{Message: "invalid session snapshot reset_reason"}
		}
		snapshot, err := decodeValue[ResourceSnapshot](
			known.Snapshot,
			"session resource snapshot",
		)
		if err != nil {
			return SessionEvent{}, err
		}
		return SessionEvent{
			Kind:        known.Kind,
			Cursor:      known.Cursor,
			ResetReason: known.ResetReason,
			Snapshot:    &snapshot,
		}, nil
	case "delta":
		var known struct {
			Kind             string             `json:"kind"`
			Cursor           *Cursor            `json:"cursor"`
			PreviousRevision *Decimal           `json:"previous_revision"`
			Revision         *Decimal           `json:"revision"`
			Changes          *[]json.RawMessage `json:"changes"`
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
		changes := make([]ResourceChange, 0, len(*known.Changes))
		for index, rawChange := range *known.Changes {
			change, err := decodeResourceChange(rawChange)
			if err != nil {
				return SessionEvent{}, &ProtocolError{
					Message: fmt.Sprintf(
						"invalid session delta change %d: %s",
						index,
						err,
					),
				}
			}
			changes = append(changes, change)
		}
		return SessionEvent{
			Kind:             known.Kind,
			Cursor:           known.Cursor,
			PreviousRevision: *known.PreviousRevision,
			Revision:         *known.Revision,
			Changes:          changes,
		}, nil
	default:
		return SessionEvent{Kind: kind, Raw: Document(fields)}, nil
	}
}

func decodeSessionJournalRecord(raw json.RawMessage) (SessionJournalRecord, error) {
	var present map[string]json.RawMessage
	if err := json.Unmarshal(raw, &present); err != nil || present == nil {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid session journal record"}
	}
	for _, field := range []string{
		"sequence", "event_id", "schema_version", "kind", "class", "replay",
		"occurred_at_ms", "committed_at_ms", "producer", "authority", "causation_id",
		"correlation_id", "causation_depth", "subjects", "sensitivity", "payload",
		"resource_revision", "previous_resource_revision",
	} {
		if _, ok := present[field]; !ok {
			return SessionJournalRecord{}, &ProtocolError{
				Message: "session journal record omitted required field " + field,
			}
		}
	}
	var wire struct {
		Sequence                 *Decimal             `json:"sequence"`
		EventID                  *string              `json:"event_id"`
		SchemaVersion            *uint32              `json:"schema_version"`
		Kind                     *string              `json:"kind"`
		Class                    *JournalClass        `json:"class"`
		Replay                   *JournalReplayPolicy `json:"replay"`
		OccurredAtMS             *Decimal             `json:"occurred_at_ms"`
		CommittedAtMS            *Decimal             `json:"committed_at_ms"`
		Producer                 *JournalProducer     `json:"producer"`
		Authority                *JournalAuthority    `json:"authority"`
		CausationID              *string              `json:"causation_id"`
		CorrelationID            *string              `json:"correlation_id"`
		CausationDepth           *uint16              `json:"causation_depth"`
		Subjects                 *[]JournalSubject    `json:"subjects"`
		Sensitivity              *JournalSensitivity  `json:"sensitivity"`
		Payload                  json.RawMessage      `json:"payload"`
		ResourceRevision         *Decimal             `json:"resource_revision"`
		PreviousResourceRevision *Decimal             `json:"previous_resource_revision"`
	}
	if err := strictDecode(raw, &wire); err != nil {
		return SessionJournalRecord{}, &ProtocolError{
			Message: "invalid session journal record: " + err.Error(),
		}
	}
	if wire.Sequence == nil || wire.EventID == nil || *wire.EventID == "" ||
		wire.SchemaVersion == nil || *wire.SchemaVersion == 0 || wire.Kind == nil ||
		*wire.Kind == "" || wire.Class == nil || wire.Replay == nil ||
		wire.OccurredAtMS == nil || wire.CommittedAtMS == nil || wire.Producer == nil ||
		wire.CausationDepth == nil || wire.Subjects == nil || wire.Sensitivity == nil ||
		len(wire.Payload) == 0 {
		return SessionJournalRecord{}, &ProtocolError{
			Message: "session journal record omitted a required field",
		}
	}
	if wire.Producer.Kind == "" || wire.Producer.ID == "" {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal producer"}
	}
	if wire.Authority != nil &&
		(wire.Authority.PrincipalID == "" || wire.Authority.LeaseID == "" ||
			wire.Authority.Generation == "" || wire.Authority.Role == "") {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal authority"}
	}
	for _, subject := range *wire.Subjects {
		if subject.Kind == "" || subject.ID == "" {
			return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal subject"}
		}
	}
	if *wire.Class != JournalClassState && *wire.Class != JournalClassObservation &&
		*wire.Class != JournalClassEffect && *wire.Class != JournalClassCheckpoint {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal class"}
	}
	if *wire.Replay != JournalReplayRequired && *wire.Replay != JournalReplayAdvisory &&
		*wire.Replay != JournalReplayNever {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal replay policy"}
	}
	if *wire.Sensitivity != JournalSensitivityPublic &&
		*wire.Sensitivity != JournalSensitivityMetadata &&
		*wire.Sensitivity != JournalSensitivitySensitive &&
		*wire.Sensitivity != JournalSensitivitySecret {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal sensitivity"}
	}
	var payload JSONValue
	if err := json.Unmarshal(wire.Payload, &payload); err != nil {
		return SessionJournalRecord{}, &ProtocolError{Message: "invalid journal payload"}
	}
	return SessionJournalRecord{
		Sequence:                 *wire.Sequence,
		EventID:                  *wire.EventID,
		SchemaVersion:            *wire.SchemaVersion,
		Kind:                     *wire.Kind,
		Class:                    *wire.Class,
		Replay:                   *wire.Replay,
		OccurredAtMS:             *wire.OccurredAtMS,
		CommittedAtMS:            *wire.CommittedAtMS,
		Producer:                 *wire.Producer,
		Authority:                wire.Authority,
		CausationID:              wire.CausationID,
		CorrelationID:            wire.CorrelationID,
		CausationDepth:           *wire.CausationDepth,
		Subjects:                 *wire.Subjects,
		Sensitivity:              *wire.Sensitivity,
		Payload:                  payload,
		ResourceRevision:         wire.ResourceRevision,
		PreviousResourceRevision: wire.PreviousResourceRevision,
	}, nil
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
	case "snapshot":
		var known struct {
			Kind       string          `json:"kind"`
			TerminalID *TerminalID     `json:"terminal_id"`
			Render     json.RawMessage `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal " + kind + " item: " + err.Error(),
			}
		}
		if known.TerminalID == nil || len(known.Render) == 0 {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "terminal " + kind + " item requires terminal_id and render",
			}
		}
		render, err := decodeRenderSnapshot(known.Render)
		if err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal snapshot render: " + err.Error(),
			}
		}
		return TerminalAttachmentItem{
			Kind: known.Kind, TerminalID: *known.TerminalID,
			RenderSnapshot: &render,
		}, nil
	case "patch":
		var known struct {
			Kind       string          `json:"kind"`
			TerminalID *TerminalID     `json:"terminal_id"`
			Render     json.RawMessage `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal patch item: " + err.Error(),
			}
		}
		if known.TerminalID == nil || len(known.Render) == 0 {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "terminal patch item requires terminal_id and render",
			}
		}
		render, err := decodeRenderPatch(known.Render)
		if err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal patch render: " + err.Error(),
			}
		}
		return TerminalAttachmentItem{
			Kind: known.Kind, TerminalID: *known.TerminalID,
			RenderPatch: &render,
		}, nil
	case "scroll":
		var known struct {
			Kind       string          `json:"kind"`
			TerminalID *TerminalID     `json:"terminal_id"`
			Scroll     json.RawMessage `json:"scroll"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "invalid terminal scroll item: " + err.Error(),
			}
		}
		if known.TerminalID == nil || len(known.Scroll) == 0 {
			return TerminalAttachmentItem{}, &ProtocolError{
				Message: "terminal scroll item requires terminal_id and scroll",
			}
		}
		scroll, err := decodeValue[RenderScroll](known.Scroll, "render scroll")
		if err != nil {
			return TerminalAttachmentItem{}, err
		}
		return TerminalAttachmentItem{
			Kind: known.Kind, TerminalID: *known.TerminalID, Scroll: &scroll,
		}, nil
	default:
		return TerminalAttachmentItem{Kind: kind, Raw: Document(fields)}, nil
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
			Kind    string          `json:"kind"`
			Browser json.RawMessage `json:"browser"`
			Size    *PixelSize      `json:"size"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser snapshot item: " + err.Error(),
			}
		}
		if len(known.Browser) == 0 || known.Size == nil ||
			known.Size.WidthPX == 0 || known.Size.HeightPX == 0 {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "browser snapshot item requires browser and a non-zero size",
			}
		}
		browser, err := decodeValue[BrowserSnapshot](
			known.Browser,
			"browser attachment snapshot",
		)
		if err != nil {
			return BrowserAttachmentItem{}, err
		}
		return BrowserAttachmentItem{
			Kind:    known.Kind,
			Browser: &browser,
			Size:    known.Size,
		}, nil
	case "frame":
		var known struct {
			Kind            string          `json:"kind"`
			MIMEType        *string         `json:"mime_type"`
			DataBase64      *string         `json:"data_base64"`
			WidthPX         *uint32         `json:"width_px"`
			HeightPX        *uint32         `json:"height_px"`
			PointerFrameSeq json.RawMessage `json:"pointer_frame_seq"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "invalid browser frame item: " + err.Error(),
			}
		}
		if known.MIMEType == nil || known.DataBase64 == nil ||
			known.WidthPX == nil || *known.WidthPX == 0 ||
			known.HeightPX == nil || *known.HeightPX == 0 ||
			len(known.PointerFrameSeq) == 0 {
			return BrowserAttachmentItem{}, &ProtocolError{
				Message: "browser frame item requires mime_type, data_base64, non-zero dimensions, and pointer_frame_seq",
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
		var pointerFrameSeq *Decimal
		if !bytes.Equal(bytes.TrimSpace(known.PointerFrameSeq), []byte("null")) {
			var value Decimal
			if err := json.Unmarshal(known.PointerFrameSeq, &value); err != nil {
				return BrowserAttachmentItem{}, &ProtocolError{
					Message: "invalid browser frame pointer_frame_seq: " + err.Error(),
				}
			}
			pointerFrameSeq = &value
		}
		return BrowserAttachmentItem{
			Kind:            known.Kind,
			MIMEType:        *known.MIMEType,
			Frame:           frame,
			WidthPX:         *known.WidthPX,
			HeightPX:        *known.HeightPX,
			PointerFrameSeq: pointerFrameSeq,
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
		return BrowserAttachmentItem{Kind: kind, Raw: Document(fields)}, nil
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
			Kind        string          `json:"kind"`
			SidebarView json.RawMessage `json:"sidebar_view"`
			Render      json.RawMessage `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar snapshot item: " + err.Error(),
			}
		}
		if len(known.SidebarView) == 0 || len(known.Render) == 0 {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar snapshot item requires sidebar_view and render",
			}
		}
		sidebarView, err := decodeValue[SidebarViewSnapshot](
			known.SidebarView,
			"sidebar attachment snapshot",
		)
		if err != nil {
			return SidebarViewItem{}, err
		}
		render, err := decodeRenderSnapshot(known.Render)
		if err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar snapshot render: " + err.Error(),
			}
		}
		return SidebarViewItem{
			Kind: known.Kind, SidebarView: &sidebarView,
			RenderSnapshot: &render,
		}, nil
	case "patch":
		var known struct {
			Kind          string          `json:"kind"`
			SidebarViewID *SidebarViewID  `json:"sidebar_view_id"`
			Render        json.RawMessage `json:"render"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar patch item: " + err.Error(),
			}
		}
		if known.SidebarViewID == nil || len(known.Render) == 0 {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar patch item requires sidebar_view_id and render",
			}
		}
		render, err := decodeRenderPatch(known.Render)
		if err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar patch render: " + err.Error(),
			}
		}
		return SidebarViewItem{
			Kind: known.Kind, SidebarViewID: *known.SidebarViewID,
			RenderPatch: &render,
		}, nil
	case "scroll":
		var known struct {
			Kind          string          `json:"kind"`
			SidebarViewID *SidebarViewID  `json:"sidebar_view_id"`
			Scroll        json.RawMessage `json:"scroll"`
		}
		if err := strictDecode(raw, &known); err != nil {
			return SidebarViewItem{}, &ProtocolError{
				Message: "invalid sidebar scroll item: " + err.Error(),
			}
		}
		if known.SidebarViewID == nil || len(known.Scroll) == 0 {
			return SidebarViewItem{}, &ProtocolError{
				Message: "sidebar scroll item requires sidebar_view_id and scroll",
			}
		}
		scroll, err := decodeValue[RenderScroll](known.Scroll, "render scroll")
		if err != nil {
			return SidebarViewItem{}, err
		}
		return SidebarViewItem{
			Kind: known.Kind, SidebarViewID: *known.SidebarViewID,
			Scroll: &scroll,
		}, nil
	default:
		return SidebarViewItem{Kind: kind, Raw: Document(fields)}, nil
	}
}

func decodeFields(raw json.RawMessage) (map[string]JSONValue, error) {
	var fields map[string]JSONValue
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&fields); err != nil {
		return nil, &ProtocolError{Message: "stream item is not an object: " + err.Error()}
	}
	return fields, nil
}

func decodeResourceChange(raw json.RawMessage) (ResourceChange, error) {
	fields, err := decodeFields(raw)
	if err != nil {
		return ResourceChange{}, err
	}
	kind, ok := fields["kind"].(string)
	if !ok || kind == "" {
		return ResourceChange{}, fmt.Errorf("resource change kind must be a non-empty string")
	}
	if kind != "upsert" && kind != "delete" {
		return ResourceChange{Kind: kind, Raw: Document(fields)}, nil
	}

	type changeBase struct {
		Kind     string          `json:"kind"`
		Sequence *uint32         `json:"sequence"`
		Resource *ResourceKind   `json:"resource"`
		ID       json.RawMessage `json:"id"`
	}
	var base changeBase
	var valueRaw json.RawMessage
	if kind == "delete" {
		if err := strictDecode(raw, &base); err != nil {
			return ResourceChange{}, err
		}
	} else {
		var upsert struct {
			Kind     string          `json:"kind"`
			Sequence *uint32         `json:"sequence"`
			Resource *ResourceKind   `json:"resource"`
			ID       json.RawMessage `json:"id"`
			Value    json.RawMessage `json:"value"`
		}
		if err := strictDecode(raw, &upsert); err != nil {
			return ResourceChange{}, err
		}
		base = changeBase{
			Kind: upsert.Kind, Sequence: upsert.Sequence,
			Resource: upsert.Resource, ID: upsert.ID,
		}
		valueRaw = upsert.Value
	}
	if base.Sequence == nil || base.Resource == nil || len(base.ID) == 0 {
		return ResourceChange{}, fmt.Errorf(
			"known resource change requires sequence, resource, and id",
		)
	}
	if kind == "upsert" && len(valueRaw) == 0 {
		return ResourceChange{}, fmt.Errorf("resource upsert requires value")
	}
	id, err := decodeResourceChangeID(*base.Resource, base.ID)
	if err != nil {
		return ResourceChange{}, err
	}
	change := ResourceChange{
		Kind: kind, Sequence: *base.Sequence, Resource: *base.Resource, ID: id,
	}
	if kind == "delete" {
		return change, nil
	}
	value, err := decodeResourceEntity(*base.Resource, valueRaw)
	if err != nil {
		return ResourceChange{}, err
	}
	if id.String() != resourceEntityID(value) {
		return ResourceChange{}, fmt.Errorf(
			"resource upsert id %s does not match value id %s",
			id,
			resourceEntityID(value),
		)
	}
	change.Value = value
	return change, nil
}

func decodeResourceChangeID(
	resource ResourceKind,
	raw json.RawMessage,
) (ResourceChangeID, error) {
	switch resource {
	case ResourceMachine:
		return decodeValue[MachineID](raw, "machine change id")
	case ResourceSession:
		return decodeValue[SessionID](raw, "session change id")
	case ResourceWorkspace:
		return decodeValue[WorkspaceID](raw, "workspace change id")
	case ResourceScreen:
		return decodeValue[ScreenID](raw, "screen change id")
	case ResourcePane:
		return decodeValue[PaneID](raw, "pane change id")
	case ResourceTab:
		return decodeValue[TabID](raw, "tab change id")
	case ResourceTerminal:
		return decodeValue[TerminalID](raw, "terminal change id")
	case ResourceBrowser:
		return decodeValue[BrowserID](raw, "browser change id")
	case ResourceClient:
		return decodeValue[ConnectedClientID](raw, "client change id")
	case ResourceNotification:
		return decodeValue[NotificationID](raw, "notification change id")
	case ResourceAgent:
		return decodeValue[AgentID](raw, "agent change id")
	case ResourcePairingRequest:
		return decodeValue[PairingRequestID](raw, "pairing request change id")
	case ResourceFrontendProjection:
		return decodeValue[ProjectionID](raw, "frontend projection change id")
	case ResourceSidebarView:
		return decodeValue[SidebarViewID](raw, "sidebar view change id")
	default:
		return nil, fmt.Errorf("unknown resource kind %q", resource)
	}
}

func decodeResourceEntity(
	resource ResourceKind,
	raw json.RawMessage,
) (ResourceEntitySnapshot, error) {
	switch resource {
	case ResourceMachine:
		return decodeValue[MachineSnapshot](raw, "machine snapshot")
	case ResourceSession:
		return decodeValue[SessionSnapshot](raw, "session snapshot")
	case ResourceWorkspace:
		return decodeValue[WorkspaceSnapshot](raw, "workspace snapshot")
	case ResourceScreen:
		return decodeValue[ScreenSnapshot](raw, "screen snapshot")
	case ResourcePane:
		return decodeValue[PaneSnapshot](raw, "pane snapshot")
	case ResourceTab:
		return decodeValue[TabSnapshot](raw, "tab snapshot")
	case ResourceTerminal:
		return decodeValue[TerminalSnapshot](raw, "terminal snapshot")
	case ResourceBrowser:
		return decodeValue[BrowserSnapshot](raw, "browser snapshot")
	case ResourceClient:
		return decodeValue[ClientSnapshot](raw, "client snapshot")
	case ResourceNotification:
		return decodeValue[NotificationSnapshot](raw, "notification snapshot")
	case ResourceAgent:
		return decodeValue[AgentSnapshot](raw, "agent snapshot")
	case ResourcePairingRequest:
		return decodeValue[PairingRequestSnapshot](raw, "pairing request snapshot")
	case ResourceFrontendProjection:
		return decodeValue[FrontendProjectionSnapshot](
			raw,
			"frontend projection snapshot",
		)
	case ResourceSidebarView:
		return decodeValue[SidebarViewSnapshot](raw, "sidebar view snapshot")
	default:
		return nil, fmt.Errorf("unknown resource kind %q", resource)
	}
}

func resourceEntityID(value ResourceEntitySnapshot) string {
	switch snapshot := value.(type) {
	case MachineSnapshot:
		return snapshot.ID.String()
	case SessionSnapshot:
		return snapshot.ID.String()
	case WorkspaceSnapshot:
		return snapshot.ID.String()
	case ScreenSnapshot:
		return snapshot.ID.String()
	case PaneSnapshot:
		return snapshot.ID.String()
	case TabSnapshot:
		return snapshot.ID.String()
	case TerminalSnapshot:
		return snapshot.ID.String()
	case BrowserSnapshot:
		return snapshot.ID.String()
	case ConnectedClientSnapshot:
		return snapshot.ID.String()
	case NotificationSnapshot:
		return snapshot.ID.String()
	case AgentSnapshot:
		return snapshot.ID.String()
	case PairingRequestSnapshot:
		return snapshot.ID.String()
	case FrontendProjectionSnapshot:
		return snapshot.ID.String()
	case SidebarViewSnapshot:
		return snapshot.ID.String()
	default:
		return ""
	}
}

func decodeRenderSnapshot(raw json.RawMessage) (RenderSnapshot, error) {
	result, err := decodeValue[RenderSnapshot](raw, "render snapshot")
	if err != nil {
		return RenderSnapshot{}, err
	}
	if err := validateRenderSnapshot(result); err != nil {
		return RenderSnapshot{}, err
	}
	return result, nil
}

func decodeRenderPatch(raw json.RawMessage) (RenderPatch, error) {
	result, err := decodeValue[RenderPatch](raw, "render patch")
	if err != nil {
		return RenderPatch{}, err
	}
	if err := validateRenderPatch(result); err != nil {
		return RenderPatch{}, err
	}
	return result, nil
}

func validateRenderSnapshot(value RenderSnapshot) error {
	if value.Size.Cols == 0 || value.Size.Rows == 0 {
		return fmt.Errorf("render snapshot size must be non-zero")
	}
	if len(value.Rows) != int(value.Size.Rows) {
		return fmt.Errorf(
			"render snapshot rows must contain exactly %d entries",
			value.Size.Rows,
		)
	}
	if !validColor(value.DefaultFG) || !validColor(value.DefaultBG) {
		return fmt.Errorf("render snapshot defaults must be #rrggbb colors")
	}
	if err := validateRenderCursor(value.Cursor); err != nil {
		return err
	}
	return validateRenderRows(value.Rows)
}

func validateRenderPatch(value RenderPatch) error {
	if err := validateRenderCursor(value.Cursor); err != nil {
		return err
	}
	if value.Size != nil {
		if value.Size.Cols == 0 || value.Size.Rows == 0 {
			return fmt.Errorf("render patch size must be non-zero")
		}
		if !value.FullReset {
			return fmt.Errorf("render patch resize requires full_reset")
		}
		if len(value.Rows) != int(value.Size.Rows) {
			return fmt.Errorf(
				"resized render patch rows must contain exactly %d entries",
				value.Size.Rows,
			)
		}
	}
	if value.DefaultFG != nil && !validColor(*value.DefaultFG) {
		return fmt.Errorf("render patch default_fg must be #rrggbb")
	}
	if value.DefaultBG != nil && !validColor(*value.DefaultBG) {
		return fmt.Errorf("render patch default_bg must be #rrggbb")
	}
	return validateRenderRows(value.Rows)
}

func validateRenderCursor(value RenderCursor) error {
	switch value.Style {
	case "block", "underline", "bar":
	default:
		return fmt.Errorf("invalid render cursor style %q", value.Style)
	}
	if value.Color != nil && !validColor(*value.Color) {
		return fmt.Errorf("render cursor color must be #rrggbb")
	}
	return nil
}

func validateRenderRows(rows []RenderRow) error {
	if rows == nil {
		return fmt.Errorf("render rows must be present")
	}
	for rowIndex, row := range rows {
		if row.Runs == nil {
			return fmt.Errorf("render row %d runs must be present", rowIndex)
		}
		for runIndex, run := range row.Runs {
			if run.Foreground != nil && !validColor(*run.Foreground) {
				return fmt.Errorf(
					"render row %d run %d fg must be #rrggbb",
					rowIndex,
					runIndex,
				)
			}
			if run.Background != nil && !validColor(*run.Background) {
				return fmt.Errorf(
					"render row %d run %d bg must be #rrggbb",
					rowIndex,
					runIndex,
				)
			}
			if run.Underline != nil {
				switch *run.Underline {
				case "single", "double", "curly", "dotted", "dashed":
				default:
					return fmt.Errorf(
						"invalid render underline %q",
						*run.Underline,
					)
				}
			}
		}
	}
	return nil
}

func validColor(value string) bool {
	if len(value) != 7 || value[0] != '#' {
		return false
	}
	for _, character := range value[1:] {
		if !(character >= '0' && character <= '9' ||
			character >= 'a' && character <= 'f' ||
			character >= 'A' && character <= 'F') {
			return false
		}
	}
	return true
}

func validateViewAttachmentOutcome(outcome ViewAttachmentOutcome) error {
	switch outcome {
	case ViewAttachmentApplied, ViewAttachmentPassive, ViewAttachmentSuperseded:
		return nil
	default:
		return fmt.Errorf("invalid view attachment outcome %q", outcome)
	}
}

func decodeRendererGrant(raw json.RawMessage) (RendererGrant, error) {
	var result struct {
		Endpoint   string     `json:"endpoint"`
		TerminalID TerminalID `json:"terminal_id"`
		Token      string     `json:"token"`
		Rights     []string   `json:"rights"`
		TTLMS      uint32     `json:"ttl_ms"`
	}
	if err := strictDecode(raw, &result); err != nil {
		return RendererGrant{}, &ProtocolError{
			Message: "cannot decode renderer grant: " + err.Error(),
		}
	}
	if result.Token == "" {
		return RendererGrant{}, &ProtocolError{Message: "renderer grant omitted token"}
	}
	if result.Endpoint == "" || len(result.Rights) == 0 ||
		result.TTLMS == 0 || result.TTLMS > 60_000 {
		return RendererGrant{}, &ProtocolError{
			Message: "renderer grant has invalid endpoint, rights, or ttl_ms",
		}
	}
	return RendererGrant{
		Endpoint: result.Endpoint, TerminalID: result.TerminalID,
		Token: NewSecret(result.Token), Rights: append([]string(nil), result.Rights...),
		TTLMS: result.TTLMS,
	}, nil
}
