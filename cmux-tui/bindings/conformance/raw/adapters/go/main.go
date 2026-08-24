// Protocol-10 conformance adapter for the public Go SDK.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

type request struct {
	ContractVersion   int    `json:"contract_version"`
	ID                any    `json:"id"`
	Op                string `json:"op"`
	SocketPath        string `json:"socket_path"`
	TimeoutMS         int    `json:"timeout_ms"`
	MaxFrameBytes     int    `json:"max_frame_bytes"`
	MaxBufferedEvents int    `json:"max_buffered_events"`
	Stream            string `json:"stream"`
	Surface           string `json:"surface"`
	Events            int    `json:"events"`
	CloseAfterMS      int    `json:"close_after_ms"`
	DeadlineMS        int    `json:"deadline_ms"`
	Authority         string `json:"authority"`
	Marker            string `json:"marker"`
	WorkspaceName     string `json:"workspace_name"`
	RenamedName       string `json:"renamed_name"`
	Presence          string `json:"presence"`
}

type adapterError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

type response struct {
	ContractVersion int           `json:"contract_version"`
	ID              any           `json:"id"`
	OK              bool          `json:"ok"`
	Value           any           `json:"value,omitempty"`
	Error           *adapterError `json:"error,omitempty"`
}

type metadataValue struct {
	Commands []commandMetadata `json:"commands"`
	Events   []eventMetadata   `json:"events"`
}

type commandMetadata struct {
	Name      string         `json:"name"`
	Authority cmux.Authority `json:"authority"`
	Stream    string         `json:"stream,omitempty"`
}

type eventMetadata struct {
	Name    string   `json:"name"`
	Streams []string `json:"streams"`
}

func main() {
	var input request
	decoder := json.NewDecoder(bufio.NewReader(os.Stdin))
	decoder.UseNumber()
	if err := decoder.Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	output := response{ContractVersion: 1, ID: input.ID}
	value, err := dispatch(input)
	if err != nil {
		output.Error = &adapterError{Kind: classify(err), Message: err.Error()}
	} else {
		output.OK = true
		output.Value = value
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(output); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func dispatch(input request) (any, error) {
	switch input.Op {
	case "metadata":
		return metadata(), nil
	case "identify":
		return identify(input)
	case "nullable-literal":
		return nullableLiteral(input)
	case "optional-non-null-response":
		return optionalNonNullResponse(input)
	case "optional-nullable-request":
		return optionalNullableRequest(input)
	case "stream":
		return runStream(input)
	case "required-nullable-event":
		return requiredNullableEvent(input)
	case "optional-non-null-event":
		return optionalNonNullEvent(input)
	case "close-pending-stream":
		return closePendingStream(input)
	case "authority":
		return authority(input)
	case "authority-denied":
		return authorityDenied(input)
	case "real-flow":
		return realFlow(input)
	default:
		return nil, fmt.Errorf("unknown adapter operation %q", input.Op)
	}
}

func metadata() metadataValue {
	commands := cmux.AllCommandMetadata()
	commandValues := make([]commandMetadata, 0, len(commands))
	for _, item := range commands {
		commandValues = append(commandValues, commandMetadata{
			Name: item.Name, Authority: item.Authority, Stream: item.Stream,
		})
	}
	events := cmux.AllEventMetadata()
	eventValues := make([]eventMetadata, 0, len(events))
	for _, item := range events {
		eventValues = append(eventValues, eventMetadata{Name: item.Name, Streams: item.Streams})
	}
	return metadataValue{Commands: commandValues, Events: eventValues}
}

func options(input request) cmux.Options {
	timeout := time.Duration(input.TimeoutMS) * time.Millisecond
	if timeout <= 0 {
		timeout = time.Second
	}
	options := cmux.Options{SocketPath: input.SocketPath, Timeout: timeout}
	if input.MaxFrameBytes > 0 {
		options.MaxResponseBytes = input.MaxFrameBytes
	}
	if input.MaxBufferedEvents > 0 {
		options.MaxBufferedStreamEvents = input.MaxBufferedEvents
	}
	return options
}

func identify(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	value, err := client.Identify(context.Background())
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"app":                value.App,
		"protocol":           value.Protocol,
		"workspace_revision": strconv.FormatUint(value.WorkspaceRevision, 10),
		"terminal_revision":  strconv.FormatUint(value.TerminalRevision, 10),
	}, nil
}

func nullableLiteral(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	value, err := client.CreateTerminal(
		context.Background(),
		cmux.CreateTerminalOptions{Key: cmux.Value("workspace-key")},
	)
	if err != nil {
		return nil, err
	}
	return map[string]any{"lifecycle": value.Lifecycle}, nil
}

func optionalNonNullResponse(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	value, err := client.Identify(context.Background())
	if err != nil {
		return nil, err
	}
	return map[string]any{"present": value.Capabilities != nil}, nil
}

func optionalNullableRequest(input request) (any, error) {
	info := cmux.SetClientInfoOptions{}
	switch input.Presence {
	case "omitted":
	case "null":
		info.Name = cmux.Null[string]()
	case "value":
		info.Name = cmux.Value("conformance-client")
	default:
		return nil, fmt.Errorf("unknown presence %q", input.Presence)
	}
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	if err := client.SetClientInfo(context.Background(), info); err != nil {
		return nil, err
	}
	return map[string]any{"presence": input.Presence}, nil
}

func openStream(client *cmux.Client, input request) (*cmux.Stream, error) {
	ctx := context.Background()
	surface, err := strconv.ParseUint(defaultString(input.Surface, "7"), 10, 64)
	if err != nil {
		return nil, err
	}
	switch input.Stream {
	case "subscribe-coarse":
		return client.Subscribe(ctx)
	case "subscribe-deltas":
		return client.SubscribeDeltas(ctx)
	case "attach-byte", "attach-browser":
		return client.AttachSurfaceWithOptions(
			ctx,
			cmux.ID(surface),
			cmux.AttachSurfaceOptions{Mode: cmux.Value(cmux.AttachBytes)},
		)
	case "attach-render":
		return client.AttachSurfaceWithOptions(
			ctx,
			cmux.ID(surface),
			cmux.AttachSurfaceOptions{Mode: cmux.Value(cmux.AttachRender)},
		)
	default:
		return nil, fmt.Errorf("unknown stream %q", input.Stream)
	}
}

func receive(stream *cmux.Stream, input request) (cmux.Event, error) {
	ctx := context.Background()
	switch input.Stream {
	case "subscribe-coarse":
		return stream.RecvSubscribe(ctx)
	case "subscribe-deltas":
		return stream.RecvDelta(ctx)
	case "attach-byte":
		return stream.RecvByte(ctx)
	case "attach-render":
		return stream.RecvRender(ctx)
	case "attach-browser":
		return stream.RecvBrowser(ctx)
	default:
		return nil, fmt.Errorf("unknown stream %q", input.Stream)
	}
}

func runStream(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	stream, err := openStream(client, input)
	if err != nil {
		return nil, err
	}
	defer stream.Close()
	count := input.Events
	if count <= 0 {
		count = 1
	}
	events := make([]any, 0, count)
	terminal := false
	for index := 0; index < count; index++ {
		event, receiveErr := receive(stream, input)
		if receiveErr != nil {
			if terminal || errors.Is(receiveErr, io.EOF) || errors.Is(receiveErr, cmux.ErrConnection) {
				terminal = true
				break
			}
			return nil, receiveErr
		}
		events = append(events, normalizeEvent(event))
		switch event.(type) {
		case cmux.OverflowEvent, cmux.DetachedEvent:
			terminal = true
		}
	}
	return map[string]any{"events": events, "terminal": terminal}, nil
}

func requiredNullableEvent(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	stream, err := openStream(client, input)
	if err != nil {
		return nil, err
	}
	defer stream.Close()
	event, err := receive(stream, input)
	if err != nil {
		return nil, err
	}
	changed, ok := event.(cmux.ClientChangedEvent)
	if !ok {
		return nil, expectedTypedEvent(event, "client-changed")
	}
	if name, present := changed.Name.Get(); present {
		return map[string]any{"name": name}, nil
	}
	if changed.Name.IsNull() {
		return map[string]any{"name": nil}, nil
	}
	return nil, fmt.Errorf("%w: client-changed name is unset", cmux.ErrDecode)
}

func optionalNonNullEvent(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	stream, err := openStream(client, input)
	if err != nil {
		return nil, err
	}
	defer stream.Close()
	event, err := receive(stream, input)
	if err != nil {
		return nil, err
	}
	output, ok := event.(cmux.OutputEvent)
	if !ok {
		return nil, expectedTypedEvent(event, "output")
	}
	return map[string]any{"present": output.Colors != nil}, nil
}

func expectedTypedEvent(event cmux.Event, expected string) error {
	if unknown, ok := event.(cmux.UnknownEvent); ok && unknown.Name == expected {
		return fmt.Errorf("%w: %s event failed typed decoding", cmux.ErrDecode, expected)
	}
	return fmt.Errorf(
		"%w: expected %s event, received %s",
		cmux.ErrDecode,
		expected,
		event.EventName(),
	)
}

func normalizeEvent(event cmux.Event) any {
	if unknown, ok := event.(cmux.UnknownEvent); ok {
		return map[string]any{
			"event": unknown.Name, "unknown": true, "raw": normalizeMap(unknown.Raw),
		}
	}
	encoded, _ := json.Marshal(event)
	decoder := json.NewDecoder(strings.NewReader(string(encoded)))
	decoder.UseNumber()
	var value map[string]any
	_ = decoder.Decode(&value)
	value["event"] = event.EventName()
	return normalizeMap(value)
}

func normalizeMap(value map[string]any) map[string]any {
	result := make(map[string]any, len(value))
	for key, item := range value {
		result[key] = normalizeValue(key, item)
	}
	return result
}

func normalizeValue(key string, value any) any {
	switch item := value.(type) {
	case map[string]any:
		return normalizeMap(item)
	case []any:
		result := make([]any, len(item))
		for index, child := range item {
			result[index] = normalizeValue("", child)
		}
		return result
	case json.Number:
		if isUint64Key(key) {
			return item.String()
		}
		if integer, err := item.Int64(); err == nil {
			return integer
		}
		return item.String()
	default:
		return value
	}
}

func isUint64Key(key string) bool {
	switch key {
	case "client", "index", "offset", "pane", "pane_revision", "projection_revision",
		"request", "screen", "seq", "surface", "terminal_revision", "timeout_ms",
		"workspace", "workspace_revision":
		return true
	default:
		return strings.HasSuffix(key, "_revision")
	}
}

func closePendingStream(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	stream, err := openStream(client, input)
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	var once sync.Once
	go func() {
		_, _ = receive(stream, input)
		once.Do(func() { close(done) })
	}()
	delay := time.Duration(input.CloseAfterMS) * time.Millisecond
	if delay <= 0 {
		delay = 50 * time.Millisecond
	}
	time.Sleep(delay)
	_ = stream.Close()
	deadline := time.Duration(input.DeadlineMS) * time.Millisecond
	if deadline <= 0 {
		deadline = time.Second
	}
	select {
	case <-done:
		return map[string]any{"unblocked": true}, nil
	case <-time.After(deadline):
		return map[string]any{"unblocked": false}, nil
	}
}

func authority(input request) (any, error) {
	clientOptions := options(input)
	clientOptions.EnableProviderAuthority = input.Authority == "provider-authority"
	client, err := cmux.NewClient(clientOptions)
	if err != nil {
		return nil, err
	}
	defer client.Close()
	ctx := context.Background()
	var command string
	switch input.Authority {
	case "control":
		_, err = client.Ping(ctx)
		command = "ping"
	case "frontend":
		err = client.BrowserBack(ctx, 7)
		command = "browser-back"
	case "local-admin":
		err = client.PairingResponse(ctx, 1, false)
		command = "pairing-response"
	case "provider-authority":
		err = client.MarkWorkspacesProviderManaged(ctx, "conformance-authority")
		command = "mark-workspaces-provider-managed"
	default:
		err = fmt.Errorf("unknown authority %q", input.Authority)
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"command": command}, nil
}

func authorityDenied(input request) (any, error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	err = client.MarkWorkspacesProviderManaged(
		context.Background(),
		"conformance-authority",
	)
	var denied *cmux.AuthorityError
	if errors.As(err, &denied) {
		return map[string]any{"denied": true}, nil
	}
	if err != nil {
		return nil, err
	}
	return nil, fmt.Errorf("default client allowed provider-authority command")
}

type surfaceContext struct {
	Workspace cmux.Workspace
	Tab       cmux.Tab
}

func findSurface(tree cmux.Tree, surface cmux.ID) (surfaceContext, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.Value.(cmux.LivePane)
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return surfaceContext{Workspace: workspace, Tab: tab}, true
					}
				}
			}
		}
	}
	return surfaceContext{}, false
}

func realFlow(input request) (value any, returnErr error) {
	client, err := cmux.NewClient(options(input))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	ctx := context.Background()
	identity, err := client.Identify(ctx)
	if err != nil {
		return nil, err
	}
	stream, err := client.SubscribeDeltas(ctx)
	if err != nil {
		return nil, err
	}
	defer stream.Close()

	marker := defaultString(input.Marker, "cmux-sdk-conformance-marker")
	workspaceName := defaultString(input.WorkspaceName, "sdk-conformance-workspace")
	renamedName := defaultString(input.RenamedName, "sdk-conformance-renamed")
	cols, rows := uint16(80), uint16(24)
	created, err := client.NewWorkspace(ctx, cmux.NewWorkspaceOptions{
		Name: cmux.Value(workspaceName), Cols: cmux.Value(cols), Rows: cmux.Value(rows),
	})
	if err != nil {
		return nil, err
	}
	var workspace cmux.ID
	closed := false
	defer func() {
		if workspace != 0 && !closed {
			_, _ = client.CloseWorkspace(
				ctx,
				cmux.CloseWorkspaceOptions{Workspace: cmux.Value(workspace)},
			)
		}
	}()

	command := fmt.Sprintf("printf '%s\\n'\r", marker)
	if err := client.Send(
		ctx,
		created.Surface,
		cmux.SendOptions{Text: cmux.Value(command)},
	); err != nil {
		return nil, err
	}
	waited, err := client.WaitFor(ctx, created.Surface, marker, 5_000)
	if err != nil {
		return nil, err
	}
	screenText, err := client.ReadScreen(ctx, created.Surface)
	if err != nil {
		return nil, err
	}
	tree, err := client.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	found, ok := findSurface(tree, created.Surface)
	if !ok {
		return nil, fmt.Errorf("created surface %d is absent from the tree", created.Surface)
	}
	workspace = found.Workspace.ID
	terminalCreated := found.Tab.Kind == "pty" && !found.Tab.Dead
	if _, err = client.RenameWorkspace(
		ctx,
		renamedName,
		cmux.RenameWorkspaceOptions{Workspace: cmux.Value(workspace)},
	); err != nil {
		return nil, err
	}
	renamedTree, err := client.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	renamed := false
	for _, item := range renamedTree.Workspaces {
		if item.ID == workspace && item.Name == renamedName {
			renamed = true
		}
	}
	if _, err = client.CloseWorkspace(
		ctx,
		cmux.CloseWorkspaceOptions{Workspace: cmux.Value(workspace)},
	); err != nil {
		return nil, err
	}
	closed = true
	remaining, err := client.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	disappeared := true
	for _, item := range remaining.Workspaces {
		if item.ID == workspace {
			disappeared = false
		}
	}

	required := []string{"workspace-added", "workspace-renamed", "workspace-closed"}
	observed := make([]string, 0, 16)
	for len(observed) < 64 {
		complete := true
		for _, name := range required {
			if !slicesContains(observed, name) {
				complete = false
			}
		}
		if complete {
			break
		}
		readCtx, cancel := context.WithTimeout(ctx, time.Duration(input.TimeoutMS)*time.Millisecond)
		event, receiveErr := stream.RecvDelta(readCtx)
		cancel()
		if receiveErr != nil {
			return nil, receiveErr
		}
		observed = append(observed, event.EventName())
	}
	previous := -1
	streamOrdered := true
	for _, name := range required {
		position := indexOf(observed, name)
		if position <= previous {
			streamOrdered = false
		}
		previous = position
	}
	return map[string]any{
		"identified":           identity.Protocol == 10,
		"workspace_created":    workspace > 0,
		"terminal_created":     terminalCreated,
		"marker_sent":          true,
		"wait_matched":         waited.Matched,
		"read_contains_marker": strings.Contains(screenText.Text, marker),
		"stream_ordered":       streamOrdered,
		"renamed":              renamed,
		"closed":               closed,
		"disappeared":          disappeared,
		"observed_events":      observed,
	}, nil
}

func slicesContains(values []string, target string) bool {
	return indexOf(values, target) >= 0
}

func indexOf(values []string, target string) int {
	for index, value := range values {
		if value == target {
			return index
		}
	}
	return -1
}

func classify(err error) string {
	text := strings.ToLower(err.Error())
	switch {
	case errors.Is(err, cmux.ErrTimeout), strings.Contains(text, "timed out"), strings.Contains(text, "deadline"):
		return "timeout"
	case errors.Is(err, cmux.ErrMessageTooLarge), errors.Is(err, cmux.ErrBufferFull),
		strings.Contains(text, "exceed"), strings.Contains(text, "too large"):
		return "limit"
	case errors.Is(err, cmux.ErrCommand):
		return "command"
	case errors.Is(err, cmux.ErrDecode), errors.Is(err, cmux.ErrProtocolMismatch),
		strings.Contains(text, "utf-8"), strings.Contains(text, "json"):
		return "decode"
	default:
		return "transport"
	}
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
