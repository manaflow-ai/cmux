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
	testPaneID      = PaneID("pane_00000000000000000000000000000005")
	testTabID       = TabID("tab_00000000000000000000000000000006")
	testTerminalID  = TerminalID("term_00000000000000000000000000000007")
	testAgentID     = AgentID("agent_00000000000000000000000000000008")
	testBrowserID   = BrowserID("browser_00000000000000000000000000000009")
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

func TestBrowserFrameRequiresNullablePointerFrameSequence(t *testing.T) {
	decode := func(pointerField string) (BrowserAttachmentItem, error) {
		return decodeBrowserAttachment(json.RawMessage(
			`{"kind":"frame","mime_type":"image/png","data_base64":"AA==",` +
				`"width_px":1,"height_px":1` + pointerField + `}`,
		))
	}

	nullFrame, err := decode(`,"pointer_frame_seq":null`)
	if err != nil || nullFrame.PointerFrameSeq != nil {
		t.Fatalf("nullable pointer frame sequence = %#v, %v", nullFrame, err)
	}
	maximumFrame, err := decode(`,"pointer_frame_seq":"18446744073709551615"`)
	if err != nil || maximumFrame.PointerFrameSeq == nil ||
		maximumFrame.PointerFrameSeq.Uint64() != ^uint64(0) {
		t.Fatalf("maximum pointer frame sequence = %#v, %v", maximumFrame, err)
	}

	for name, pointerField := range map[string]string{
		"missing":       "",
		"number":        `,"pointer_frame_seq":7`,
		"non-canonical": `,"pointer_frame_seq":"07"`,
		"overflow":      `,"pointer_frame_seq":"18446744073709551616"`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decode(pointerField); !errors.Is(err, ErrProtocol) {
				t.Fatalf("error = %T %v", err, err)
			}
		})
	}
}

func TestBrowserPointerInputsEncodeRequiredDecimalToken(t *testing.T) {
	client, requests := pipeClient(t, nil, 2)
	defer client.Close(context.Background()) //nolint:errcheck
	browser := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Browser(SelectID(testBrowserID))
	button := "left"
	maximum := Decimal(^uint64(0))

	if _, err := browser.Mouse(context.Background(), BrowserInputMouseOptions{
		MutationOptions: MutationOptions{
			Extra: map[string]JSONValue{"pointer_frame_seq": nil},
		},
		Kind:            "down",
		XPX:             10.5,
		YPX:             20.5,
		Button:          &button,
		PointerFrameSeq: maximum,
	}); err != nil {
		t.Fatalf("mouse: %v", err)
	}
	if _, err := browser.Wheel(context.Background(), BrowserInputWheelOptions{
		DeltaX:          1.25,
		DeltaY:          -2.5,
		XPX:             30.5,
		YPX:             40.5,
		PointerFrameSeq: Decimal(42),
	}); err != nil {
		t.Fatalf("wheel: %v", err)
	}

	mouse := <-requests
	if mouse["operation"] != "browser.input.mouse" {
		t.Fatalf("mouse operation = %#v", mouse["operation"])
	}
	requireParam(t, mouse, "pointer_frame_seq", "18446744073709551615")
	wheel := <-requests
	if wheel["operation"] != "browser.input.wheel" {
		t.Fatalf("wheel operation = %#v", wheel["operation"])
	}
	requireParam(t, wheel, "pointer_frame_seq", "42")
}

func TestCatalogResultsDecodeStrictly(t *testing.T) {
	for name, raw := range map[string]json.RawMessage{
		"external origin": json.RawMessage(
			`{"id":"machine_00000000000000000000000000000001",` +
				`"name":"external","origin":"external","status":"running",` +
				`"connectable":true,"deleted":false,"recoverable":true}`,
		),
		"provider scope": json.RawMessage(
			`{"id":"machine_00000000000000000000000000000001",` +
				`"name":"local","origin":"local","status":"running",` +
				`"connectable":true,` +
				`"provider_scope_id":"provider_scope_00000000000000000000000000000001",` +
				`"deleted":false,"recoverable":true}`,
		),
	} {
		if _, err := decodeValue[MachineSnapshot](raw, "machine snapshot"); !errors.Is(err, ErrProtocol) {
			t.Fatalf("%s error = %T %v", name, err, err)
		}
	}

	state, err := decodeValue[TerminalStateResult](
		json.RawMessage(`{"state_base64":"AAEC","cols":80,"rows":24}`),
		"terminal state",
	)
	if err != nil || !strings.EqualFold(fmt.Sprintf("%x", state.State), "000102") {
		t.Fatalf("terminal state = %#v, %v", state, err)
	}
	if _, err := decodeValue[TerminalCopyResult](
		json.RawMessage(`{"mode":"future","text":"x"}`),
		"terminal copy",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("invalid copy mode error = %T %v", err, err)
	}
	terminal, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_id":"tab_00000000000000000000000000000006",`+
				`"title":"job","cols":80,"rows":24,"running":false,`+
				`"lifecycle":"exited","exit":{`+
				`"outcome":{"kind":"exit","code":0},`+
				`"exited_at":"20","revision":"21"}}`,
		),
		"terminal snapshot",
	)
	if err != nil || terminal.Exit == nil {
		t.Fatalf("exited terminal snapshot = %#v, %v", terminal, err)
	}
	if outcome, ok := terminal.Exit.Outcome.(TerminalExitCode); !ok ||
		outcome.Code != 0 {
		t.Fatalf(
			"terminal snapshot exit outcome = %T %#v",
			terminal.Exit.Outcome,
			terminal.Exit.Outcome,
		)
	}
	if _, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_id":"tab_00000000000000000000000000000006",`+
				`"title":"job","cols":80,"rows":24,"running":true,`+
				`"lifecycle":"exited","exit":{`+
				`"outcome":{"kind":"exit","code":0},`+
				`"exited_at":"20","revision":"21"}}`,
		),
		"terminal snapshot",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("inconsistent terminal lifecycle error = %T %v", err, err)
	}
	if _, err := decodeValue[TerminalScreenResult](
		json.RawMessage(
			`{"text":"","cols":80,"rows":24,"cursor_row":0,"cursor_col":0,`+
				`"cursor_visible":true,"unexpected":1}`,
		),
		"terminal screen",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("unknown terminal screen field error = %T %v", err, err)
	}
	if _, err := decodeValue[PingResult](
		json.RawMessage(`{"alive":true,"cursor":{"generation":"g"}}`),
		"ping",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("incomplete nested cursor error = %T %v", err, err)
	}
	layout, err := decodeValue[LayoutDocument](
		json.RawMessage(
			`{"version":1,`+
				`"screen_id":"screen_00000000000000000000000000000004",`+
				`"active_pane_id":"pane_00000000000000000000000000000005",`+
				`"zoomed_pane_id":null,`+
				`"root":{"kind":"leaf",`+
				`"pane_id":"pane_00000000000000000000000000000005",`+
				`"tab_ids":[]}}`,
		),
		"layout",
	)
	if err != nil {
		t.Fatalf("valid layout: %v", err)
	}
	if _, ok := layout.Root.(LayoutLeaf); !ok {
		t.Fatalf("layout root type = %T", layout.Root)
	}
	if _, err := decodeValue[LayoutDocument](
		json.RawMessage(
			`{"version":1,`+
				`"screen_id":"screen_00000000000000000000000000000004",`+
				`"active_pane_id":"pane_00000000000000000000000000000005",`+
				`"zoomed_pane_id":null,`+
				`"root":{"kind":"leaf",`+
				`"pane_id":"pane_00000000000000000000000000000005",`+
				`"tab_ids":[],"future":true}}`,
		),
		"layout",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("unknown nested layout field error = %T %v", err, err)
	}

	creation, err := decodeValue[CreationResolution](
		json.RawMessage(
			`{"correlation_key":"create-1","state":"created","recovery":"none",`+
				`"created_path":{"kind":"terminal",`+
				`"workspace_id":"ws_00000000000000000000000000000003",`+
				`"screen_id":"screen_00000000000000000000000000000004",`+
				`"pane_id":"pane_00000000000000000000000000000005",`+
				`"tab_id":"tab_00000000000000000000000000000006",`+
				`"terminal_id":"term_00000000000000000000000000000007"},`+
				`"generation":"g","revision":"4"}`,
		),
		"creation resolution",
	)
	if err != nil || creation.CreatedPath == nil ||
		creation.CreatedPath.Terminal != testTerminalID {
		t.Fatalf("created resolution = %#v, %v", creation, err)
	}
	if _, err := decodeValue[CreationResolution](
		json.RawMessage(
			`{"correlation_key":"create-1","state":"created","recovery":"wait",`+
				`"created_path":null,"generation":"g","revision":"4"}`,
		),
		"creation resolution",
	); !errors.Is(err, ErrProtocol) {
		t.Fatalf("invalid creation resolution error = %T %v", err, err)
	}

	waitExit, err := decodeTerminalWaitExitResult(
		json.RawMessage(
			`{"state":"exited",` +
				`"terminal_id":"term_00000000000000000000000000000007",` +
				`"lifecycle":"exited",` +
				`"outcome":{"kind":"exit","code":0},` +
				`"exited_at":"5","revision":"6"}`,
		),
	)
	exited, ok := waitExit.(TerminalWaitExitExited)
	if err != nil || !ok {
		t.Fatalf("terminal wait exit = %T %#v, %v", waitExit, waitExit, err)
	}
	if outcome, ok := exited.Outcome.(TerminalExitCode); !ok || outcome.Code != 0 {
		t.Fatalf("terminal exit outcome = %T %#v", exited.Outcome, exited.Outcome)
	}
	if _, err := decodeTerminalWaitExitResult(
		json.RawMessage(
			`{"state":"exited",` +
				`"terminal_id":"term_00000000000000000000000000000007",` +
				`"lifecycle":"exited",` +
				`"outcome":{"kind":"signal","signal":0,"core_dumped":false},` +
				`"exited_at":"5","revision":"6"}`,
		),
	); err == nil {
		t.Fatal("zero terminal exit signal was accepted")
	}
}

func TestCreationResolveAndWaitExitFacades(t *testing.T) {
	client, requests := pipeClient(t, nil, 2)
	defer client.Close(context.Background()) //nolint:errcheck

	session := client.Session(SelectID(testSessionID))
	resolution, err := session.ResolveCreation(
		context.Background(),
		"create-1",
		SessionCreationResolveOptions{},
	)
	if err != nil {
		t.Fatalf("resolve creation: %v", err)
	}
	if resolution.State != CreationResolutionPending ||
		resolution.Recovery != CreationWait {
		t.Fatalf("creation resolution = %#v", resolution)
	}

	timeout := Decimal(250)
	terminal := session.Terminal(SelectID(testTerminalID))
	result, err := terminal.WaitExit(context.Background(), TerminalWaitExitOptions{
		TimeoutMS: &timeout,
	})
	if err != nil {
		t.Fatalf("wait exit: %v", err)
	}
	exited, ok := result.(TerminalWaitExitExited)
	if !ok {
		t.Fatalf("wait exit result = %T %#v", result, result)
	}
	signal, ok := exited.Outcome.(TerminalExitSignal)
	if !ok || signal.Signal != 15 || signal.CoreDumped {
		t.Fatalf("exit outcome = %T %#v", exited.Outcome, exited.Outcome)
	}

	creationRequest := <-requests
	if creationRequest["operation"] != "session.creation.resolve" {
		t.Fatalf("creation operation = %#v", creationRequest["operation"])
	}
	requireParam(t, creationRequest, "correlation_key", "create-1")
	exitRequest := <-requests
	if exitRequest["operation"] != "terminal.wait_exit" {
		t.Fatalf("exit operation = %#v", exitRequest["operation"])
	}
	requireParam(t, exitRequest, "timeout_ms", "250")
	exitParams := requestParams(t, exitRequest)
	for _, ancestor := range []string{"workspace", "screen", "pane", "tab"} {
		if _, exists := exitParams[ancestor]; exists {
			t.Fatalf("session-scoped wait exit included %s: %#v", ancestor, exitParams)
		}
	}
}

func TestSessionReportAgentUsesOnlySessionRoute(t *testing.T) {
	client, requests := pipeClient(t, nil, 1)
	defer client.Close(context.Background()) //nolint:errcheck

	sourceSession := "codex-task-42"
	revision := Decimal(12)
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	result, err := session.ReportAgent(
		context.Background(),
		AgentReportOptions{
			MutationOptions: MutationOptions{
				IdempotencyKey:   "agent-report-1",
				ExpectedRevision: &revision,
			},
			TerminalID:    testTerminalID,
			State:         AgentStateWorking,
			Source:        AgentReportSourceSocket,
			SourceSession: &sourceSession,
		},
	)
	if err != nil {
		t.Fatalf("report agent: %v", err)
	}
	if result.Value.Snapshot().ID != testAgentID ||
		result.Value.Snapshot().State != AgentStateWorking ||
		result.Revision.Uint64() != 13 {
		t.Fatalf("agent mutation result = %#v", result)
	}

	request := <-requests
	if request["operation"] != "agent.report" {
		t.Fatalf("agent report operation = %#v", request["operation"])
	}
	if request["idempotency_key"] != "agent-report-1" {
		t.Fatalf("agent report idempotency = %#v", request["idempotency_key"])
	}
	requireParam(t, request, "machine", testMachineID.String())
	requireParam(t, request, "session", testSessionID.String())
	requireParam(t, request, "terminal_id", testTerminalID.String())
	requireParam(t, request, "state", string(AgentStateWorking))
	requireParam(t, request, "source", string(AgentReportSourceSocket))
	requireParam(t, request, "source_session", sourceSession)
	requireParam(t, request, "expected_revision", "12")
	if _, exists := requestParams(t, request)["agent"]; exists {
		t.Fatalf("session agent report included an agent selector: %#v", request)
	}
}

func TestKnownResourceChangesAreTypedAndNeverDowngradeToUnknown(t *testing.T) {
	machine := map[string]any{
		"id":          testMachineID,
		"name":        "local",
		"origin":      "local",
		"status":      "running",
		"connectable": true,
		"deleted":     false,
		"recoverable": true,
	}
	encoded, err := json.Marshal(map[string]any{
		"kind":              "delta",
		"cursor":            map[string]any{"generation": "g", "revision": "2"},
		"previous_revision": "1",
		"revision":          "2",
		"changes": []any{map[string]any{
			"kind": "upsert", "sequence": 0, "resource": "machine",
			"id": testMachineID, "value": machine,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	event, err := decodeSessionEvent(encoded)
	if err != nil {
		t.Fatalf("decode typed delta: %v", err)
	}
	if len(event.Changes) != 1 {
		t.Fatalf("changes = %#v", event.Changes)
	}
	snapshot, ok := event.Changes[0].Value.(MachineSnapshot)
	if !ok || snapshot.ID != testMachineID {
		t.Fatalf("typed resource value = %T %#v", event.Changes[0].Value, snapshot)
	}

	mismatch := make(map[string]any, len(machine))
	for key, value := range machine {
		mismatch[key] = value
	}
	mismatch["id"] = "machine_00000000000000000000000000000009"
	bad, err := json.Marshal(map[string]any{
		"kind": "upsert", "sequence": 0, "resource": "machine",
		"id": testMachineID, "value": mismatch,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeResourceChange(bad); err == nil {
		t.Fatal("mismatched known resource upsert was accepted")
	}

	knownWithExtra, err := json.Marshal(map[string]any{
		"kind": "delete", "sequence": 1, "resource": "machine",
		"id": testMachineID, "value": machine,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeResourceChange(knownWithExtra); err == nil {
		t.Fatal("malformed known delete downgraded to Unknown")
	}

	unknown, err := decodeResourceChange(
		json.RawMessage(`{"kind":"future","nested":{"revision":18446744073709551615}}`),
	)
	if err != nil || unknown.Kind != "future" || unknown.Raw == nil {
		t.Fatalf("unknown resource change = %#v, %v", unknown, err)
	}
	if _, ok := unknown.Raw["nested"].(map[string]any); !ok {
		t.Fatalf("unknown raw object = %#v", unknown.Raw)
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
	canceledContext, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := workspace.Rename(
		canceledContext,
		WorkspaceRenameOptions{Name: "never-sent"},
	); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled mutation error = %T %v", err, err)
	} else {
		var uncertain *MutationTransportUncertainError
		if errors.As(err, &uncertain) {
			t.Fatalf("pre-canceled mutation was reported uncertain: %#v", uncertain)
		}
	}
	first, err := workspace.Rename(context.Background(), WorkspaceRenameOptions{Name: ""})
	if err != nil {
		t.Fatalf("workspace rename: %v", err)
	}
	if first.Revision.Uint64() != ^uint64(0) {
		t.Fatalf("revision = %s", first.Revision)
	}
	if first.Value != workspace {
		t.Fatalf("workspace rename returned a different handle: %p != %p", first.Value, workspace)
	}
	if snapshot, ok := workspace.Cached(); !ok || snapshot.Name != "" {
		t.Fatalf("workspace cache after rename = %#v, %v", snapshot, ok)
	}

	empty := ""
	screen := workspace.Screen(SelectID(testScreenID))
	screenRename, err := screen.Rename(context.Background(), ScreenRenameOptions{
		MutationOptions: MutationOptions{IdempotencyKey: "same-key"},
		Name:            &empty,
	})
	if err != nil {
		t.Fatalf("screen empty-label rename: %v", err)
	}
	if screenRename.Value != screen {
		t.Fatalf("screen rename returned a different handle: %p != %p", screenRename.Value, screen)
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
		MutationOptions: MutationOptions{CorrelationKey: "run-1"},
		Command:         Exact("printf", "%s", "$HOME; rm -rf never"),
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
	requireParam(t, exactRequest, "correlation_key", "run-1")
	shellRequest := <-requests
	shellParams := requestParams(t, shellRequest)
	if shellParams["shell"] != `printf '%s\n' "$HOME"` {
		t.Fatalf("shell script changed: %#v", shellParams)
	}
	if _, ok := shellParams["argv"]; ok {
		t.Fatalf("shell command also encoded argv")
	}
}

func TestScreenLayoutUndoEncodesConfirmationToken(t *testing.T) {
	client, requests := pipeClient(t, nil, 1)
	defer client.Close(context.Background()) //nolint:errcheck
	screen := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Workspace(SelectID(testWorkspaceID)).
		Screen(SelectID(testScreenID))
	token := "undo-preview-token"

	if _, err := screen.UndoLayout(context.Background(), ScreenLayoutUndoOptions{
		ConfirmClose: true,
	}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("missing confirmation token error = %T %v", err, err)
	}
	if _, err := screen.UndoLayout(context.Background(), ScreenLayoutUndoOptions{
		MutationOptions:   MutationOptions{IdempotencyKey: "undo-key"},
		ConfirmClose:      true,
		ConfirmationToken: &token,
	}); err != nil {
		t.Fatalf("undo layout: %v", err)
	}
	request := <-requests
	if request["operation"] != "screen.layout.undo" {
		t.Fatalf("undo operation = %#v", request["operation"])
	}
	requireParam(t, request, "confirm_close", true)
	requireParam(t, request, "confirmation_token", token)
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

func TestConfirmationRequiredDetailsDecodeStrictly(t *testing.T) {
	resourceError := &ResourceError{
		Code: "confirmation.required",
		Details: json.RawMessage(
			`{"confirmation_token":"undo-preview-token","revision":"9",` +
				`"closes_panes":["pane_00000000000000000000000000000005"]}`,
		),
	}
	var details ConfirmationRequiredDetails
	if err := resourceError.DecodeDetails(&details); err != nil {
		t.Fatalf("decode confirmation details: %v", err)
	}
	if details.ConfirmationToken != "undo-preview-token" ||
		details.Revision != Decimal(9) ||
		len(details.ClosesPanes) != 1 ||
		details.ClosesPanes[0] != testPaneID {
		t.Fatalf("confirmation details = %#v", details)
	}

	resourceError.Details = json.RawMessage(
		`{"confirmation_token":"","revision":"9","closes_panes":[]}`,
	)
	if err := resourceError.DecodeDetails(&details); !errors.Is(err, ErrProtocol) {
		t.Fatalf("invalid confirmation details error = %T %v", err, err)
	}
}

func TestDroppedMutationResponseExposesExactIdempotencyKey(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		explicit  string
		generated string
		expected  string
	}{
		{
			name: "supplied", explicit: "supplied-key",
			generated: "must-not-be-used", expected: "supplied-key",
		},
		{
			name: "generated", generated: "generated-key",
			expected: "generated-key",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			clientSide, serverSide := net.Pipe()
			requests := make(chan map[string]any, 1)
			release := make(chan struct{})
			go func() {
				defer serverSide.Close()
				requests <- readRequest(t, bufio.NewReader(serverSide))
				<-release
			}()
			client, err := NewClient(context.Background(), ClientOptions{
				IdempotencyKey: func() (string, error) {
					return testCase.generated, nil
				},
				DialContext: func(context.Context, string, string) (net.Conn, error) {
					return clientSide, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				close(release)
				_ = client.Close(context.Background())
			})
			workspace := client.Machine(SelectID(testMachineID)).
				Session(SelectID(testSessionID)).
				Workspace(SelectID(testWorkspaceID))
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
			defer cancel()
			_, err = workspace.Rename(ctx, WorkspaceRenameOptions{
				MutationOptions: MutationOptions{
					IdempotencyKey: testCase.explicit,
				},
				Name: "uncertain",
			})
			var uncertain *MutationTransportUncertainError
			if !errors.As(err, &uncertain) {
				t.Fatalf("error type = %T: %v", err, err)
			}
			if uncertain.Operation != "workspace.rename" ||
				uncertain.IdempotencyKey != testCase.expected ||
				uncertain.Recovery() != "inspect_state_then_retry_with_new_key" ||
				!errors.Is(uncertain, context.DeadlineExceeded) {
				t.Fatalf("uncertain mutation error = %#v", uncertain)
			}
			request := <-requests
			if request["idempotency_key"] != testCase.expected {
				t.Fatalf("wire idempotency key = %#v", request["idempotency_key"])
			}
		})
	}
}

func TestStreamRecvDeadlineIsOperationScoped(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})

		ping := readRequest(t, reader)
		if ping["operation"] != "session.ping" {
			t.Errorf("request after receive timeout = %#v", ping["operation"])
			return
		}
		writeSuccess(t, serverSide, ping["id"], map[string]any{
			"alive": true,
			"cursor": map[string]any{
				"generation": "g",
				"revision":   "17",
			},
		})
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_item",
			"stream_id": streamID,
			"sequence":  "18",
			"item": map[string]any{
				"kind":  "future-session-item",
				"value": true,
			},
		})

		cancel := readRequest(t, reader)
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
	defer client.Close(context.Background()) //nolint:errcheck
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	stream, err := session.Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	receiveContext, cancelReceive := context.WithTimeout(
		context.Background(),
		10*time.Millisecond,
	)
	_, err = stream.Recv(receiveContext)
	cancelReceive()
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("bounded receive error = %T %v", err, err)
	}
	ping, err := session.Ping(context.Background(), SessionPingOptions{})
	if err != nil || !ping.Alive || ping.Cursor.Revision != Decimal(17) {
		t.Fatalf("ping after receive timeout = %#v, %v", ping, err)
	}
	item, err := stream.Recv(context.Background())
	if err != nil || item.Sequence != Decimal(18) ||
		item.Value.Kind != "future-session-item" {
		t.Fatalf("stream after receive timeout = %#v, %v", item, err)
	}
	if err := stream.Cancel(context.Background()); err != nil {
		t.Fatalf("cancel stream: %v", err)
	}
}

func TestAcknowledgedStreamOutlivesSetupContextAndRequestTimeout(t *testing.T) {
	const requestTimeout = 10 * time.Millisecond
	clientSide, serverSide := net.Pipe()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})

		timer := time.NewTimer(4 * requestTimeout)
		defer timer.Stop()
		<-timer.C
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_item",
			"stream_id": streamID,
			"sequence":  "1",
			"item": map[string]any{
				"kind":          "delayed-session-item",
				"after_timeout": true,
			},
		})

		cancel := readRequest(t, reader)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/1",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "canceled",
		})
		writeSuccess(t, serverSide, cancel["id"], map[string]any{})
	}()

	setupContext, cancelSetup := context.WithCancel(context.Background())
	client, err := NewClient(setupContext, ClientOptions{
		Timeout: requestTimeout,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		cancelSetup()
		t.Fatal(err)
	}
	defer client.Close(context.Background()) //nolint:errcheck
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	stream, err := session.Events(setupContext, SessionEventsOptions{})
	cancelSetup()
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	if !errors.Is(setupContext.Err(), context.Canceled) {
		t.Fatalf("setup context = %v, want canceled", setupContext.Err())
	}

	receiveContext, cancelReceive := context.WithTimeout(context.Background(), time.Second)
	item, err := stream.Recv(receiveContext)
	cancelReceive()
	if err != nil {
		t.Fatalf("receive delayed item: %v", err)
	}
	if item.Sequence != Decimal(1) ||
		item.Value.Kind != "delayed-session-item" ||
		item.Value.Raw["after_timeout"] != true {
		t.Fatalf("delayed stream item = %#v", item)
	}

	cancelContext, cancelStream := context.WithTimeout(context.Background(), time.Second)
	err = stream.Cancel(cancelContext)
	cancelStream()
	if err != nil {
		t.Fatalf("cancel delayed stream: %v", err)
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("server did not observe stream cancellation")
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
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
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
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
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
			case "browser.input.mouse", "browser.input.wheel":
				result = map[string]any{
					"generation": "g",
					"revision":   "1",
					"replayed":   false,
					"value":      map[string]any{},
				}
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
			case "screen.rename", "screen.layout.undo":
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
						"layout": map[string]any{
							"version":        1,
							"screen_id":      testScreenID,
							"active_pane_id": "pane_00000000000000000000000000000005",
							"zoomed_pane_id": nil,
							"root": map[string]any{
								"kind":    "leaf",
								"pane_id": "pane_00000000000000000000000000000005",
								"tab_ids": []any{},
							},
						},
					},
				}
			case "client.metadata.update":
				result = map[string]any{
					"id":                    "client_00000000000000000000000000000005",
					"session_id":            testSessionID,
					"name":                  nil,
					"client_kind":           "",
					"transport":             "unix",
					"connected_seconds":     "0",
					"attached_terminal_ids": []any{},
					"sizes":                 []any{},
					"self":                  true,
				}
			case "session.creation.resolve":
				result = map[string]any{
					"correlation_key": "create-1",
					"state":           "pending",
					"recovery":        "wait",
					"operation":       "workspace.create",
					"idempotency_key": "create-key",
				}
			case "terminal.wait_exit":
				result = map[string]any{
					"state":       "exited",
					"terminal_id": testTerminalID,
					"lifecycle":   "exited",
					"outcome": map[string]any{
						"kind":        "signal",
						"signal":      15,
						"core_dumped": false,
					},
					"exited_at": "10",
					"revision":  "11",
				}
			case "agent.report":
				result = map[string]any{
					"generation": "g",
					"revision":   "13",
					"replayed":   false,
					"value": map[string]any{
						"id":             testAgentID,
						"session_id":     testSessionID,
						"terminal_id":    testTerminalID,
						"state":          AgentStateWorking,
						"source":         AgentSourceSocket,
						"updated_at_ms":  "14",
						"source_session": "codex-task-42",
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
			"pane_id":      testPaneID,
			"tab_id":       testTabID,
			"terminal_id":  testTerminalID,
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
