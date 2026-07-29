package cmux

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testMachineID   = MachineID("machine_00000000000000000000000000000001")
	testSessionID   = SessionID("session_00000000000000000000000000000002")
	testWorkspaceID = WorkspaceID("ws_00000000000000000000000000000003")
	testScreenID    = ScreenID("screen_00000000000000000000000000000004")
)

func TestIDsSelectorsAndDecimals(t *testing.T) {
	if _, err := ParseWorkspaceID(string(testWorkspaceID)); err != nil {
		t.Fatalf("valid workspace ID rejected: %v", err)
	}
	for _, invalid := range []string{
		"workspace_00000000000000000000000000000003",
		"ws_0000000000000000000000000000000A",
		"ws_short",
	} {
		if _, err := ParseWorkspaceID(invalid); !errors.Is(err, ErrInvalidID) {
			t.Fatalf("ParseWorkspaceID(%q) error = %v", invalid, err)
		}
	}
	if got := SelectName[WorkspaceID]("").String(); got != "name:" {
		t.Fatalf("empty exact-name selector = %q", got)
	}
	if got := SelectName[WorkspaceID](string(testWorkspaceID)).String(); got != "name:"+string(testWorkspaceID) {
		t.Fatalf("ID-shaped name selector = %q", got)
	}

	var maximum Decimal
	if err := json.Unmarshal([]byte(`"18446744073709551615"`), &maximum); err != nil {
		t.Fatalf("full uint64 decimal rejected: %v", err)
	}
	if maximum.Uint64() != ^uint64(0) {
		t.Fatalf("decimal = %d", maximum.Uint64())
	}
	encoded, err := json.Marshal(maximum)
	if err != nil || string(encoded) != `"18446744073709551615"` {
		t.Fatalf("decimal encoding = %s, %v", encoded, err)
	}
	for _, invalid := range []string{`1`, `"01"`, `"-1"`, `"18446744073709551616"`} {
		if err := json.Unmarshal([]byte(invalid), &maximum); err == nil {
			t.Fatalf("invalid decimal accepted: %s", invalid)
		}
	}
}

func TestMutationIdempotencyAndNameNullability(t *testing.T) {
	var generated atomic.Int32
	client, requests := pipeClient(t, func() (string, error) {
		generated.Add(1)
		return "deterministic-key", nil
	}, 4)
	defer client.Close(context.Background()) //nolint:errcheck

	workspace := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Workspace(SelectID(testWorkspaceID))
	first, err := workspace.Rename(context.Background(), WorkspaceRenameOptions{Name: ""})
	if err != nil {
		t.Fatalf("workspace rename: %v", err)
	}
	if first.Revision.Uint64() != ^uint64(0) {
		t.Fatalf("revision = %s", first.Revision)
	}

	empty := ""
	screen := workspace.Screen(SelectID(testScreenID))
	if _, err := screen.Rename(context.Background(), ScreenRenameOptions{
		MutationOptions: MutationOptions{IdempotencyKey: "same-key"},
		Name:            &empty,
	}); err != nil {
		t.Fatalf("screen empty-label rename: %v", err)
	}
	if _, err := screen.Rename(context.Background(), ScreenRenameOptions{
		MutationOptions: MutationOptions{IdempotencyKey: "same-key"},
		Name:            nil,
	}); err != nil {
		t.Fatalf("screen clear-label rename: %v", err)
	}

	connected := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		ConnectedClient(SelectID(ConnectedClientID("client_00000000000000000000000000000005")))
	if _, err := connected.UpdateMetadata(context.Background(), ConnectedClientMetadataUpdateOptions{
		Name: NullString(),
		Kind: ValueString(""),
	}); err != nil {
		t.Fatalf("client metadata: %v", err)
	}

	captured := make([]map[string]any, 0, 4)
	for index := 0; index < 4; index++ {
		captured = append(captured, <-requests)
	}
	if got := captured[0]["idempotency_key"]; got != "deterministic-key" {
		t.Fatalf("generated idempotency key = %#v", got)
	}
	if generated.Load() != 1 {
		t.Fatalf("key source called %d times", generated.Load())
	}
	requireParam(t, captured[0], "name", "")
	requireParam(t, captured[1], "name", "")
	if got := captured[1]["idempotency_key"]; got != "same-key" {
		t.Fatalf("explicit idempotency key = %#v", got)
	}
	if value, ok := requestParams(t, captured[2])["name"]; !ok || value != nil {
		t.Fatalf("screen clear must encode name:null, params = %#v", requestParams(t, captured[2]))
	}
	if _, ok := captured[3]["idempotency_key"]; ok {
		t.Fatalf("connection-control metadata included idempotency key")
	}
	metadata := requestParams(t, captured[3])
	if value, ok := metadata["name"]; !ok || value != nil {
		t.Fatalf("metadata name clear = %#v", metadata)
	}
	if value, ok := metadata["kind"]; !ok || value != "" {
		t.Fatalf("metadata kind exact empty = %#v", metadata)
	}
}

func TestCommandsRemainExactAndShellIsServerSide(t *testing.T) {
	client, requests := pipeClient(t, nil, 2)
	defer client.Close(context.Background()) //nolint:errcheck
	workspace := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Workspace(SelectID(testWorkspaceID))

	if _, err := workspace.Run(context.Background(), WorkspaceRunOptions{
		Command: Exact("printf", "%s", "$HOME; rm -rf never"),
	}); err != nil {
		t.Fatalf("exact run: %v", err)
	}
	if _, err := workspace.Run(context.Background(), WorkspaceRunOptions{
		Command: Shell(`printf '%s\n' "$HOME"`),
	}); err != nil {
		t.Fatalf("shell run: %v", err)
	}
	exactRequest := <-requests
	exactParams := requestParams(t, exactRequest)
	argv, ok := exactParams["argv"].([]any)
	if !ok || len(argv) != 3 || argv[2] != "$HOME; rm -rf never" {
		t.Fatalf("exact argv changed: %#v", exactParams)
	}
	if _, ok := exactParams["shell"]; ok {
		t.Fatalf("exact command also encoded shell")
	}
	shellRequest := <-requests
	shellParams := requestParams(t, shellRequest)
	if shellParams["shell"] != `printf '%s\n' "$HOME"` {
		t.Fatalf("shell script changed: %#v", shellParams)
	}
	if _, ok := shellParams["argv"]; ok {
		t.Fatalf("shell command also encoded argv")
	}
}

func TestStructuredErrorsAndNoImplicitRetry(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	var requests atomic.Int32
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		request := readRequest(t, reader)
		requests.Add(1)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol": "cmux.protocol/1",
			"type":     "response",
			"id":       request["id"],
			"ok":       false,
			"error": map[string]any{
				"code":      "selector.ambiguous",
				"message":   "ambiguous",
				"details":   map[string]any{"candidates": []any{testWorkspaceID.String()}},
				"retryable": true,
			},
		})
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	workspace := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Workspace(SelectID(testWorkspaceID))
	_, err = workspace.Rename(context.Background(), WorkspaceRenameOptions{Name: "api"})
	var resourceError *ResourceError
	if !errors.As(err, &resourceError) {
		t.Fatalf("error type = %T: %v", err, err)
	}
	if resourceError.Code != "selector.ambiguous" || !resourceError.Retryable ||
		!strings.Contains(string(resourceError.Details), "candidates") {
		t.Fatalf("resource error lost fields: %#v", resourceError)
	}
	time.Sleep(10 * time.Millisecond)
	if requests.Load() != 1 {
		t.Fatalf("mutation was retried %d times", requests.Load())
	}
}

func TestTypedStreamEndAndCancellation(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cancelRequests := make(chan int, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{})
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_item",
			"stream_id": streamID,
			"sequence":  "18446744073709551615",
			"cursor": map[string]any{
				"generation": "g",
				"revision":   "18446744073709551615",
			},
			"item": map[string]any{
				"kind":      "future-session-item",
				"data":      map[string]any{"future": true},
				"new_field": "preserved",
			},
		})
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "gap",
			"error": map[string]any{
				"code":      "stream.gap",
				"message":   "resume required",
				"details":   map[string]any{"cursor": "old"},
				"retryable": true,
			},
			"recovery": "refresh session snapshot",
		})
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	stream, err := session.Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	item, err := stream.Recv(context.Background())
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if item.Sequence.Uint64() != ^uint64(0) ||
		item.Value.Kind != "future-session-item" ||
		item.Value.Raw["new_field"] != "preserved" {
		t.Fatalf("typed stream item = %#v", item)
	}
	_, err = stream.Recv(context.Background())
	var end *StreamEndError
	if !errors.As(err, &end) || end.Reason != "gap" ||
		end.ResourceError == nil || end.ResourceError.Code != "stream.gap" {
		t.Fatalf("stream end = %T %#v", err, err)
	}
	if _, err := stream.Recv(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("post-end recv = %v", err)
	}
	if err := stream.Cancel(context.Background()); err != nil {
		t.Fatalf("post-end cancel: %v", err)
	}
	select {
	case count := <-cancelRequests:
		t.Fatalf("unexpected cancel request count %d", count)
	default:
	}
}

func TestCancelPreservesOpeningRouteAndServerEnd(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cancelRequests := make(chan map[string]any, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		openParams := requestParams(t, open)
		streamID := openParams["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{})
		cancel := readRequest(t, reader)
		cancelParams := requestParams(t, cancel)
		cancelRequests <- cancelParams
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "canceled",
		})
		writeSuccess(t, serverSide, cancel["id"], map[string]any{})
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background())
	session := client.Machine(SelectCurrent[MachineID]()).
		Session(SelectID(testSessionID))
	stream, err := session.Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	if err := stream.Cancel(context.Background()); err != nil {
		t.Fatalf("cancel stream: %v", err)
	}
	if err := stream.Cancel(context.Background()); err != nil {
		t.Fatalf("repeat cancel stream: %v", err)
	}
	params := <-cancelRequests
	if params["machine"] != "current" ||
		params["session"] != testSessionID.String() ||
		params["stream"] != stream.ID().String() {
		t.Fatalf("cancel route = %#v", params)
	}
	if _, exists := params["stream_id"]; exists {
		t.Fatalf("cancel used stream_id: %#v", params)
	}
	if end := stream.End(); end == nil || end.Reason != "canceled" {
		t.Fatalf("cancel end = %#v", end)
	}
}

func TestSecretFormattingRedactsTokens(t *testing.T) {
	token := "renderer-super-secret-token"
	grant := RendererGrant{Token: NewSecret(token)}
	for _, formatted := range []string{
		fmt.Sprint(grant.Token),
		fmt.Sprintf("%#v", grant.Token),
		fmt.Sprint(grant),
		fmt.Sprintf("%#v", grant),
	} {
		if strings.Contains(formatted, token) || !strings.Contains(formatted, "redacted") {
			t.Fatalf("unsafe secret formatting: %q", formatted)
		}
	}
	encoded, err := json.Marshal(grant.Token)
	if err != nil || string(encoded) != `"`+token+`"` {
		t.Fatalf("secret wire encoding = %s, %v", encoded, err)
	}
	credential := ProviderCredential{Name: "token", Value: NewSecret(token)}
	if strings.Contains(fmt.Sprintf("%#v", credential), token) {
		t.Fatalf("provider credential formatting leaked token")
	}
}

func TestSlowConsumerQueueBoundsEndOnlyThatStream(t *testing.T) {
	for name, messages := range map[string][]streamMessage{
		"message count": func() []streamMessage {
			result := make([]streamMessage, MaxStreamQueueMessages+1)
			for index := range result {
				result[index] = streamMessage{
					envelope: streamEnvelope{Type: "stream_item"},
					size:     1,
				}
			}
			return result
		}(),
		"encoded bytes": {
			{envelope: streamEnvelope{Type: "stream_item"}, size: MaxStreamQueueBytes},
			{envelope: streamEnvelope{Type: "stream_item"}, size: 1},
		},
	} {
		t.Run(name, func(t *testing.T) {
			route := &streamRoute{
				messages:  make(chan streamMessage, MaxStreamQueueMessages+1),
				accepting: true,
			}
			for index, message := range messages {
				delivered := route.deliver(message)
				if index != len(messages)-1 && !delivered {
					t.Fatalf("message %d rejected before bound", index)
				}
				if index == len(messages)-1 && delivered {
					t.Fatalf("overflow message %d accepted", index)
				}
			}
			route.overflow()
			terminal := <-route.messages
			var end *StreamEndError
			if !errors.As(terminal.err, &end) || end.Reason != "gap" ||
				end.ResourceError == nil || end.ResourceError.Code != "stream.local_overflow" ||
				end.Recovery == "" {
				t.Fatalf("overflow terminal = %#v", terminal.err)
			}
		})
	}
}

func TestOversizedUnterminatedFrameIsBounded(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	go func() {
		defer serverSide.Close()
		_ = readRequest(t, bufio.NewReader(serverSide))
		_, _ = serverSide.Write([]byte(strings.Repeat("x", 66)))
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		MaxResponseBytes: 64,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	_, err = session.Ping(context.Background(), SessionPingOptions{})
	var protocolError *ProtocolError
	if !errors.As(err, &protocolError) || !strings.Contains(protocolError.Error(), "exceeds 64") {
		t.Fatalf("oversized frame error = %T %v", err, err)
	}
}

func TestCancelDeliveryRace(t *testing.T) {
	for iteration := 0; iteration < 1_000; iteration++ {
		route := &streamRoute{
			messages:  make(chan streamMessage, MaxStreamQueueMessages+1),
			accepting: true,
		}
		start := make(chan struct{})
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			<-start
			route.deliver(streamMessage{
				envelope: streamEnvelope{Type: "stream_item"},
				size:     10,
			})
		}()
		go func() {
			defer wait.Done()
			<-start
			route.finish(ErrClosed)
		}()
		close(start)
		wait.Wait()
		select {
		case terminal := <-route.messages:
			if terminal.err == nil {
				t.Fatalf("iteration %d retained data after cancellation", iteration)
			}
		default:
			t.Fatalf("iteration %d did not unblock receiver", iteration)
		}
	}
}

func pipeClient(
	t *testing.T,
	keySource IdempotencyKeyFunc,
	expectedRequests int,
) (*Client, <-chan map[string]any) {
	t.Helper()
	clientSide, serverSide := net.Pipe()
	requests := make(chan map[string]any, expectedRequests)
	go func() {
		defer serverSide.Close()
		defer close(requests)
		reader := bufio.NewReader(serverSide)
		for index := 0; index < expectedRequests; index++ {
			request := readRequest(t, reader)
			requests <- request
			result := map[string]any{}
			switch request["operation"] {
			case "workspace.run":
				result = createdPathResult()
			case "workspace.rename":
				result = map[string]any{
					"generation": "g",
					"revision":   "18446744073709551615",
					"replayed":   index > 0,
					"value": map[string]any{
						"id":         testWorkspaceID,
						"session_id": testSessionID,
						"name":       "",
						"index":      0,
						"focused":    true,
					},
				}
			case "screen.rename":
				result = map[string]any{
					"generation": "g",
					"revision":   "18446744073709551615",
					"replayed":   index > 0,
					"value": map[string]any{
						"id":           testScreenID,
						"workspace_id": testWorkspaceID,
						"name":         nil,
						"index":        0,
						"focused":      true,
						"layout":       map[string]any{},
					},
				}
			}
			writeSuccess(t, serverSide, request["id"], result)
		}
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		IdempotencyKey: keySource,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return client, requests
}

func createdPathResult() map[string]any {
	return map[string]any{
		"generation": "g",
		"revision":   "1",
		"replayed":   false,
		"value": map[string]any{
			"kind":         "terminal",
			"workspace_id": testWorkspaceID,
			"screen_id":    testScreenID,
			"pane_id":      "pane_00000000000000000000000000000005",
			"tab_id":       "tab_00000000000000000000000000000006",
			"terminal_id":  "term_00000000000000000000000000000007",
		},
	}
}

func readRequest(t *testing.T, reader *bufio.Reader) map[string]any {
	t.Helper()
	line, err := reader.ReadBytes('\n')
	if err != nil {
		t.Errorf("read request: %v", err)
		return nil
	}
	var request map[string]any
	if err := json.Unmarshal(line, &request); err != nil {
		t.Errorf("decode request: %v", err)
		return nil
	}
	return request
}

func writeSuccess(t *testing.T, conn net.Conn, id any, result map[string]any) {
	t.Helper()
	writeEnvelope(t, conn, map[string]any{
		"protocol": "cmux.protocol/1",
		"type":     "response",
		"id":       id,
		"ok":       true,
		"result":   result,
	})
}

func writeEnvelope(t *testing.T, conn net.Conn, envelope map[string]any) {
	t.Helper()
	encoded, err := json.Marshal(envelope)
	if err != nil {
		t.Errorf("encode response: %v", err)
		return
	}
	encoded = append(encoded, '\n')
	if _, err := conn.Write(encoded); err != nil {
		t.Errorf("write response: %v", err)
	}
}

func requestParams(t *testing.T, request map[string]any) map[string]any {
	t.Helper()
	value, ok := request["params"].(map[string]any)
	if !ok {
		t.Fatalf("params = %#v", request["params"])
	}
	return value
}

func requireParam(t *testing.T, request map[string]any, key string, expected any) {
	t.Helper()
	if actual := requestParams(t, request)[key]; actual != expected {
		t.Fatalf("%s = %#v, want %#v", key, actual, expected)
	}
}
