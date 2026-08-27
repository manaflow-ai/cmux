package cmux

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"runtime"
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

func TestSessionJournalOptionsValidation(t *testing.T) {
	tail := JournalStartTail
	invalidStart := JournalStart("latest")
	secret := JournalSensitivitySecret
	invalidSensitivity := JournalSensitivity("private")
	invalidClass := JournalClass("transition")
	emptyRegex := &JournalRegexFilter{}
	invalidFieldRegex := &JournalRegexFilter{
		Pattern: "agent\\.",
		Field:   JournalRegexField("unknown"),
	}
	tests := map[string]SessionJournalOptions{
		"cursor and start": {
			Cursor: &Cursor{Generation: "generation", Revision: Decimal(1)},
			Start:  &tail,
		},
		"invalid start": {Start: &invalidStart},
		"secret sensitivity": {
			Filter: &JournalFilter{MaxSensitivity: &secret},
		},
		"invalid sensitivity": {
			Filter: &JournalFilter{MaxSensitivity: &invalidSensitivity},
		},
		"invalid class": {
			Filter: &JournalFilter{Classes: []JournalClass{invalidClass}},
		},
		"empty subject": {
			Filter: &JournalFilter{Subjects: []JournalSubjectFilter{{}}},
		},
		"empty regex": {
			Filter: &JournalFilter{Regex: emptyRegex},
		},
		"invalid regex field": {
			Filter: &JournalFilter{Regex: invalidFieldRegex},
		},
	}
	for name, options := range tests {
		t.Run(name, func(t *testing.T) {
			if err := options.validate(); !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("validate() error = %v, want ErrInvalidArgument", err)
			}
		})
	}
	if err := (SessionJournalOptions{}).validate(); err != nil {
		t.Fatalf("zero-value options rejected: %v", err)
	}
}

func TestIdempotencyKeysMatchDurableIdentifierContract(t *testing.T) {
	for name, value := range map[string]string{
		"empty":           "",
		"unicode spaces":  " \u00a0\u3000",
		"ascii control":   "key\ncontrol",
		"unicode control": "key\u0085control",
		"over byte limit": strings.Repeat("é", 65),
		"invalid UTF-8":   "key\xff",
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateIdempotencyKey(value); !errors.Is(err, ErrInvalidArgument) {
				t.Fatalf("error = %T %v", err, err)
			}
		})
	}
	for name, value := range map[string]string{
		"surrounding spaces": " key ",
		"format scalar":      "\ufeff",
		"exact byte limit":   strings.Repeat("é", 64),
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateIdempotencyKey(value); err != nil {
				t.Fatalf("error = %v", err)
			}
		})
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

func TestTerminalProjectEncodesDestinationAndDecodesEveryView(t *testing.T) {
	client, requests := pipeClient(t, nil, 1)
	defer client.Close(context.Background()) //nolint:errcheck
	name := "mirror"
	terminal := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID))
	projected, err := terminal.Project(context.Background(), TerminalProjectOptions{
		DestinationWorkspace: SelectID(testWorkspaceID),
		DestinationScreen:    SelectID(testScreenID),
		DestinationPane:      SelectID(testPaneID),
		Index:                2,
		Name:                 &name,
	})
	if err != nil {
		t.Fatalf("project terminal: %v", err)
	}
	snapshot, ok := projected.Value.Cached()
	if !ok || snapshot.ID != TabID("tab_0000000000000000000000000000000a") ||
		snapshot.ContentID != testTerminalID || snapshot.PaneID != testPaneID {
		t.Fatalf("projected terminal snapshot = %#v, cached = %v", snapshot, ok)
	}
	projectedRoute := projected.Value.route.params()
	if projectedRoute["workspace"] != string(testWorkspaceID) ||
		projectedRoute["screen"] != string(testScreenID) ||
		projectedRoute["pane"] != string(testPaneID) ||
		projectedRoute["tab"] != string(snapshot.ID) {
		t.Fatalf("projected tab route = %#v", projectedRoute)
	}
	if _, present := projectedRoute["terminal"]; present {
		t.Fatalf("projected tab retained source terminal route = %#v", projectedRoute)
	}

	request := <-requests
	if request["operation"] != "terminal.project" {
		t.Fatalf("operation = %#v", request["operation"])
	}
	requireParam(t, request, "destination_workspace", string(testWorkspaceID))
	requireParam(t, request, "destination_screen", string(testScreenID))
	requireParam(t, request, "destination_pane", string(testPaneID))
	requireParam(t, request, "index", float64(2))
	requireParam(t, request, "name", name)
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
	legacyAttached, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_id":"tab_00000000000000000000000000000006",`+
				`"title":"legacy","cols":80,"rows":24,"running":true,`+
				`"lifecycle":"running"}`,
		),
		"legacy attached terminal snapshot",
	)
	if err != nil || len(legacyAttached.TabIDs) != 1 {
		t.Fatalf("legacy attached terminal = %#v, %v", legacyAttached, err)
	}
	legacyDetached, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_id":null,`+
				`"title":"legacy","cols":80,"rows":24,`+
				`"running":true,"lifecycle":"running"}`,
		),
		"legacy detached terminal snapshot",
	)
	if err != nil || legacyDetached.TabIDs == nil || len(legacyDetached.TabIDs) != 0 {
		t.Fatalf("legacy detached terminal = %#v, %v", legacyDetached, err)
	}
	dualPlacement, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_id":"tab_00000000000000000000000000000006",`+
				`"tab_ids":["tab_00000000000000000000000000000006"],`+
				`"title":"dual","cols":80,"rows":24,"running":true,`+
				`"lifecycle":"running"}`,
		),
		"dual terminal placement",
	)
	if err != nil || len(dualPlacement.TabIDs) != 1 {
		t.Fatalf("dual terminal placement = %#v, %v", dualPlacement, err)
	}
	terminal, err := decodeValue[TerminalSnapshot](
		json.RawMessage(
			`{"id":"term_00000000000000000000000000000007",`+
				`"tab_ids":["tab_00000000000000000000000000000006"],`+
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
				`"tab_ids":["tab_00000000000000000000000000000006"],`+
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

func TestTerminalSnapshotsRejectMalformedTabIdentities(t *testing.T) {
	const tabID = "tab_00000000000000000000000000000006"
	tests := []struct {
		name       string
		selected   any
		projected  []any
		omitTabID  bool
		omitTabIDs bool
	}{
		{name: "missing legacy and multiview identities", omitTabID: true, omitTabIDs: true},
		{name: "empty legacy compatibility alias", selected: "", omitTabIDs: true},
		{name: "empty selected identity", selected: "", projected: []any{""}},
		{name: "empty projected identity", selected: tabID, projected: []any{tabID, ""}},
		{name: "null multiview identities", selected: tabID, projected: nil},
		{
			name:      "inconsistent legacy alias",
			selected:  "tab_11111111111111111111111111111111",
			projected: []any{tabID},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fields := map[string]any{
				"id":        "term_00000000000000000000000000000007",
				"title":     "job",
				"cols":      80,
				"rows":      24,
				"running":   true,
				"lifecycle": "running",
			}
			if !test.omitTabID {
				fields["tab_id"] = test.selected
			}
			if !test.omitTabIDs {
				fields["tab_ids"] = test.projected
			}
			raw, err := json.Marshal(fields)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := decodeValue[TerminalSnapshot](raw, "terminal snapshot"); !errors.Is(err, ErrProtocol) {
				t.Fatalf("malformed terminal identity error = %T %v", err, err)
			}
		})
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

func TestTerminalWaitTimeoutCancelsAndGatesConcurrentReuse(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cancelSeen := make(chan map[string]any, 1)
	nextRequest := make(chan map[string]any, 1)
	releaseCancel := make(chan struct{})
	serverDone := make(chan error, 1)
	const followers = 4
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		wait := readRequest(t, reader)
		if wait["operation"] != "terminal.wait" {
			serverDone <- fmt.Errorf("wait operation = %#v", wait["operation"])
			return
		}
		cancel := readRequest(t, reader)
		if cancel["operation"] != "request.cancel" {
			serverDone <- fmt.Errorf(
				"cancel operation = %#v",
				cancel["operation"],
			)
			return
		}
		if requestParams(t, cancel)["request_id"] != wait["id"] {
			serverDone <- fmt.Errorf(
				"cancel target = %#v, want %#v",
				requestParams(t, cancel)["request_id"],
				wait["id"],
			)
			return
		}
		cancelSeen <- cancel
		go func() {
			nextRequest <- readRequest(t, reader)
		}()
		<-releaseCancel
		writeSuccess(t, serverSide, cancel["id"], map[string]any{
			"canceled": true,
		})
		for index := 0; index < followers; index++ {
			var ping map[string]any
			if index == 0 {
				ping = <-nextRequest
			} else {
				ping = readRequest(t, reader)
			}
			if ping["operation"] != "session.ping" {
				serverDone <- fmt.Errorf(
					"post-cleanup operation = %#v",
					ping["operation"],
				)
				return
			}
			writeSuccess(t, serverSide, ping["id"], pingResult())
		}
		serverDone <- nil
	}()

	client := resourceClientForConn(t, clientSide)
	terminal := client.Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID))
	waitContext, cancelWait := context.WithTimeout(
		context.Background(),
		20*time.Millisecond,
	)
	defer cancelWait()
	waitDone := make(chan error, 1)
	go func() {
		_, err := terminal.Wait(waitContext, TerminalWaitOptions{
			Pattern: "ready",
		})
		waitDone <- err
	}()

	<-cancelSeen
	pingDone := make(chan error, followers)
	for index := 0; index < followers; index++ {
		go func() {
			_, err := client.Session(SelectID(testSessionID)).
				Ping(context.Background(), SessionPingOptions{})
			pingDone <- err
		}()
	}
	select {
	case request := <-nextRequest:
		t.Fatalf(
			"request %#v reused connection before cancel confirmation",
			request["operation"],
		)
	case <-time.After(40 * time.Millisecond):
	}
	close(releaseCancel)

	if err := <-waitDone; !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("wait error = %T %v", err, err)
	}
	for index := 0; index < followers; index++ {
		if err := <-pingDone; err != nil {
			t.Fatalf("ping follower %d: %v", index, err)
		}
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestTerminalWaitExitAbortDrainsFalseRaceBeforeReuse(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	waitSeen := make(chan struct{})
	falseConfirmed := make(chan struct{})
	releaseTarget := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		wait := readRequest(t, reader)
		if wait["operation"] != "terminal.wait_exit" {
			serverDone <- fmt.Errorf("wait operation = %#v", wait["operation"])
			return
		}
		close(waitSeen)
		cancel := readRequest(t, reader)
		if cancel["operation"] != "request.cancel" {
			serverDone <- fmt.Errorf(
				"cancel operation = %#v",
				cancel["operation"],
			)
			return
		}
		writeSuccess(t, serverSide, cancel["id"], map[string]any{
			"canceled": false,
		})
		close(falseConfirmed)
		<-releaseTarget
		writeSuccess(t, serverSide, wait["id"], terminalWaitExitResult())

		ping := readRequest(t, reader)
		if ping["operation"] != "session.ping" {
			serverDone <- fmt.Errorf(
				"post-race operation = %#v",
				ping["operation"],
			)
			return
		}
		writeSuccess(t, serverSide, ping["id"], pingResult())
		serverDone <- nil
	}()

	client := resourceClientForConn(t, clientSide)
	terminal := client.Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID))
	waitContext, cancelWait := context.WithCancel(context.Background())
	waitDone := make(chan error, 1)
	go func() {
		_, err := terminal.WaitExit(
			waitContext,
			TerminalWaitExitOptions{},
		)
		waitDone <- err
	}()
	<-waitSeen
	cancelWait()
	<-falseConfirmed
	select {
	case err := <-waitDone:
		t.Fatalf("wait returned before target response drain: %v", err)
	case <-time.After(40 * time.Millisecond):
	}
	close(releaseTarget)
	if err := <-waitDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("wait error = %T %v", err, err)
	}
	if _, err := client.Session(SelectID(testSessionID)).
		Ping(context.Background(), SessionPingOptions{}); err != nil {
		t.Fatalf("ping after false race: %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestTerminalWaitAbortDrainsResponseFirstFalseRaceBeforeReuse(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	waitSeen := make(chan struct{})
	targetSent := make(chan struct{})
	releaseCancel := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		wait := readRequest(t, reader)
		close(waitSeen)
		cancel := readRequest(t, reader)
		writeSuccess(t, serverSide, wait["id"], map[string]any{
			"matched": true,
			"text":    "raced",
		})
		close(targetSent)
		<-releaseCancel
		writeSuccess(t, serverSide, cancel["id"], map[string]any{
			"canceled": false,
		})
		ping := readRequest(t, reader)
		writeSuccess(t, serverSide, ping["id"], pingResult())
		serverDone <- nil
	}()

	client := resourceClientForConn(t, clientSide)
	terminal := client.Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID))
	waitContext, cancelWait := context.WithCancel(context.Background())
	waitDone := make(chan error, 1)
	go func() {
		_, err := terminal.Wait(
			waitContext,
			TerminalWaitOptions{Pattern: "ready"},
		)
		waitDone <- err
	}()
	<-waitSeen
	cancelWait()
	<-targetSent
	select {
	case err := <-waitDone:
		t.Fatalf("wait returned before cancel response drain: %v", err)
	case <-time.After(40 * time.Millisecond):
	}
	close(releaseCancel)
	if err := <-waitDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("wait error = %T %v", err, err)
	}
	if _, err := client.Session(SelectID(testSessionID)).
		Ping(context.Background(), SessionPingOptions{}); err != nil {
		t.Fatalf("ping after response-first race: %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestTerminalWaitCleanupFailureClosesButPreservesAbort(t *testing.T) {
	for _, testCase := range []struct {
		name         string
		cancelResult map[string]any
		targetResult map[string]any
	}{
		{
			name: "malformed cancel confirmation",
			cancelResult: map[string]any{
				"canceled": true,
				"extra":    true,
			},
		},
		{
			name:         "malformed false-race target",
			cancelResult: map[string]any{"canceled": false},
			targetResult: map[string]any{"matched": true},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			clientSide, serverSide := net.Pipe()
			waitSeen := make(chan struct{})
			go func() {
				defer serverSide.Close()
				reader := bufio.NewReader(serverSide)
				wait := readRequest(t, reader)
				close(waitSeen)
				cancel := readRequest(t, reader)
				writeSuccess(
					t,
					serverSide,
					cancel["id"],
					testCase.cancelResult,
				)
				if testCase.targetResult != nil {
					writeSuccess(
						t,
						serverSide,
						wait["id"],
						testCase.targetResult,
					)
				}
				var trailing [1]byte
				_, _ = serverSide.Read(trailing[:])
			}()

			client := resourceClientForConn(t, clientSide)
			terminal := client.Session(SelectID(testSessionID)).
				Terminal(SelectID(testTerminalID))
			waitContext, cancelWait := context.WithCancel(context.Background())
			waitDone := make(chan error, 1)
			go func() {
				_, err := terminal.Wait(
					waitContext,
					TerminalWaitOptions{Pattern: "ready"},
				)
				waitDone <- err
			}()
			<-waitSeen
			cancelWait()
			if err := <-waitDone; !errors.Is(err, context.Canceled) {
				t.Fatalf("wait error = %T %v", err, err)
			}
			select {
			case <-client.done:
			default:
				t.Fatal("cleanup failure did not close the connection")
			}
			started := time.Now()
			if _, err := client.Session(SelectID(testSessionID)).
				Ping(
					context.Background(),
					SessionPingOptions{},
				); err == nil {
				t.Fatal("request after cleanup failure succeeded")
			}
			if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
				t.Fatalf("closed connection reuse took %s", elapsed)
			}
		})
	}
}

func TestTerminalWaitCleanupDeadlineFailClosesButPreservesAbort(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	waitSeen := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		_ = readRequest(t, reader)
		close(waitSeen)
		cancel := readRequest(t, reader)
		if cancel["operation"] != "request.cancel" {
			serverDone <- fmt.Errorf(
				"cancel operation = %#v",
				cancel["operation"],
			)
			return
		}
		if err := serverSide.SetReadDeadline(
			time.Now().Add(2 * time.Second),
		); err != nil {
			serverDone <- err
			return
		}
		var byte [1]byte
		_, err := serverSide.Read(byte[:])
		if err == nil {
			serverDone <- errors.New("cleanup timeout did not close the connection")
			return
		}
		serverDone <- nil
	}()

	client := resourceClientForConn(t, clientSide)
	waitContext, cancelWait := context.WithCancel(context.Background())
	waitDone := make(chan error, 1)
	go func() {
		_, err := client.Session(SelectID(testSessionID)).
			Terminal(SelectID(testTerminalID)).
			Wait(waitContext, TerminalWaitOptions{Pattern: "ready"})
		waitDone <- err
	}()
	<-waitSeen
	started := time.Now()
	cancelWait()
	if err := <-waitDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("wait error = %T %v", err, err)
	}
	if elapsed := time.Since(started); elapsed > 1500*time.Millisecond {
		t.Fatalf("request cleanup exceeded its deadline: %s", elapsed)
	}
	select {
	case <-client.done:
	default:
		t.Fatal("request cleanup timeout did not close the connection")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestTerminalWaitPreCanceledContextSendsNothing(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	noRequest := make(chan error, 1)
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		if err := serverSide.SetReadDeadline(
			time.Now().Add(40 * time.Millisecond),
		); err != nil {
			noRequest <- err
			return
		}
		reader := bufio.NewReader(serverSide)
		var request map[string]any
		err := json.NewDecoder(reader).Decode(&request)
		if err == nil {
			noRequest <- fmt.Errorf(
				"pre-canceled wait sent %#v",
				request["operation"],
			)
			return
		}
		var timeout net.Error
		if !errors.As(err, &timeout) || !timeout.Timeout() {
			noRequest <- err
			return
		}
		noRequest <- nil
		if err := serverSide.SetReadDeadline(time.Time{}); err != nil {
			serverDone <- err
			return
		}
		ping := readRequest(t, reader)
		writeSuccess(t, serverSide, ping["id"], pingResult())
		serverDone <- nil
	}()

	client := resourceClientForConn(t, clientSide)
	waitContext, cancelWait := context.WithCancel(context.Background())
	cancelWait()
	_, err := client.Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID)).
		Wait(waitContext, TerminalWaitOptions{Pattern: "ready"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled wait error = %T %v", err, err)
	}
	if err := <-noRequest; err != nil {
		t.Fatal(err)
	}
	if _, err := client.Session(SelectID(testSessionID)).
		Ping(context.Background(), SessionPingOptions{}); err != nil {
		t.Fatalf("connection after pre-cancel: %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestTerminalWaitUncertainSendClosesWithoutCancel(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	sendError := errors.New("wait send failed after complete frame")
	wrappedClient := &fullFrameWriteErrorConn{
		Conn: clientSide,
		err:  sendError,
	}
	observed := make(chan map[string]any, 1)
	trailing := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		observed <- readRequest(t, reader)
		var extra map[string]any
		err := json.NewDecoder(reader).Decode(&extra)
		if err == nil {
			trailing <- fmt.Errorf(
				"uncertain send appended %#v",
				extra["operation"],
			)
			return
		}
		trailing <- nil
	}()

	client := resourceClientForConn(t, wrappedClient)
	_, err := client.Session(SelectID(testSessionID)).
		Terminal(SelectID(testTerminalID)).
		Wait(
			context.Background(),
			TerminalWaitOptions{Pattern: "ready"},
		)
	if !errors.Is(err, sendError) {
		t.Fatalf("wait send error = %T %v", err, err)
	}
	if request := <-observed; request["operation"] != "terminal.wait" {
		t.Fatalf("operation = %#v", request["operation"])
	}
	if err := <-trailing; err != nil {
		t.Fatal(err)
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

func TestPaneSplitEncodesViewportWidth(t *testing.T) {
	client, requests := pipeClient(t, nil, 1)
	defer client.Close(context.Background()) //nolint:errcheck
	pane := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Workspace(SelectID(testWorkspaceID)).
		Screen(SelectID(testScreenID)).
		Pane(SelectID(testPaneID))
	width := 0.5

	if _, err := pane.Split(context.Background(), PaneSplitOptions{
		Direction:     DirectionRight,
		ViewportWidth: &width,
	}); err != nil {
		t.Fatalf("split pane: %v", err)
	}
	request := <-requests
	if request["operation"] != "pane.split" {
		t.Fatalf("split operation = %#v", request["operation"])
	}
	requireParam(t, request, "direction", string(DirectionRight))
	requireParam(t, request, "viewport_width", width)
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
			"protocol": "cmux.protocol/2",
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
			"protocol":  "cmux.protocol/2",
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
			"protocol":  "cmux.protocol/2",
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

func TestJournalRecordSequenceMatchesEnvelopeCursor(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	release := make(chan struct{})
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{"stream_id": streamID})
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/2",
			"type":      "stream_item",
			"stream_id": streamID,
			"sequence":  "1",
			"cursor": map[string]any{
				"generation": string(testSessionID),
				"revision":   "1",
			},
			"item": map[string]any{
				"sequence":                   "2",
				"event_id":                   "event_mismatched_cursor",
				"schema_version":             1,
				"kind":                       "agent.turn.completed",
				"class":                      "observation",
				"replay":                     "advisory",
				"occurred_at_ms":             "1",
				"committed_at_ms":            "2",
				"producer":                   map[string]any{"kind": "agent_adapter", "id": "cmux_agents"},
				"authority":                  nil,
				"causation_id":               nil,
				"correlation_id":             nil,
				"causation_depth":            0,
				"subjects":                   []any{},
				"sensitivity":                "metadata",
				"payload":                    map[string]any{},
				"resource_revision":          nil,
				"previous_resource_revision": nil,
			},
		})
		<-release
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
	stream, err := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID)).
		Journal(context.Background(), SessionJournalOptions{})
	if err != nil {
		t.Fatalf("open journal: %v", err)
	}
	_, err = stream.Recv(context.Background())
	if !errors.Is(err, ErrProtocol) || !strings.Contains(err.Error(), "journal sequence must match") {
		t.Fatalf("mismatched journal cursor error = %T %v", err, err)
	}
	close(release)
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
			"protocol":  "cmux.protocol/2",
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
			"protocol":  "cmux.protocol/2",
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

func TestFailedStreamOpenCancelsDispatchedRoute(t *testing.T) {
	testCases := []struct {
		name          string
		result        map[string]any
		cancelContext bool
		wantError     error
	}{
		{
			name:      "deadline before acknowledgment",
			wantError: context.DeadlineExceeded,
		},
		{
			name:          "cancellation before acknowledgment",
			cancelContext: true,
			wantError:     context.Canceled,
		},
		{
			name:      "malformed acknowledgment",
			result:    map[string]any{"stream_id": 7},
			wantError: ErrProtocol,
		},
		{
			name: "mismatched acknowledgment",
			result: map[string]any{
				"stream_id": "stream_ffffffffffffffffffffffffffffffff",
			},
			wantError: ErrProtocol,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			clientSide, serverSide := net.Pipe()
			openSeen := make(chan struct{})
			cleanupSeen := make(chan struct{})
			serverDone := make(chan struct{})
			go func() {
				defer close(serverDone)
				defer serverSide.Close()
				reader := bufio.NewReader(serverSide)
				open := readRequest(t, reader)
				openParams := requestParams(t, open)
				firstStreamID := openParams["stream_id"]
				close(openSeen)
				if testCase.result != nil {
					writeSuccess(t, serverSide, open["id"], testCase.result)
				}

				cleanup := readRequest(t, reader)
				if cleanup["operation"] != "stream.cancel" {
					t.Errorf(
						"cleanup operation = %#v",
						cleanup["operation"],
					)
					return
				}
				cleanupParams := requestParams(t, cleanup)
				if cleanupParams["stream"] != firstStreamID ||
					cleanupParams["machine"] != string(testMachineID) ||
					cleanupParams["session"] != string(testSessionID) {
					t.Errorf("cleanup route = %#v", cleanupParams)
					return
				}
				// Prove a response that arrives after the failed opening call is
				// ignored without stealing the cancellation response.
				if testCase.result == nil {
					writeSuccess(t, serverSide, open["id"], map[string]any{
						"stream_id": firstStreamID,
					})
				}
				writeSuccess(t, serverSide, cleanup["id"], map[string]any{})
				close(cleanupSeen)

				// The server-side stream quota becomes available only after the
				// abandoned stream is canceled.
				secondOpen := readRequest(t, reader)
				secondStreamID := requestParams(t, secondOpen)["stream_id"]
				writeSuccess(t, serverSide, secondOpen["id"], map[string]any{
					"stream_id": secondStreamID,
				})
				secondCancel := readRequest(t, reader)
				writeEnvelope(t, serverSide, map[string]any{
					"protocol":  "cmux.protocol/2",
					"type":      "stream_end",
					"stream_id": secondStreamID,
					"reason":    "canceled",
				})
				writeSuccess(
					t,
					serverSide,
					secondCancel["id"],
					map[string]any{},
				)
			}()

			client, err := NewClient(context.Background(), ClientOptions{
				Timeout: 100 * time.Millisecond,
				DialContext: func(context.Context, string, string) (net.Conn, error) {
					return clientSide, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close(context.Background()) //nolint:errcheck
			session := client.Machine(SelectID(testMachineID)).
				Session(SelectID(testSessionID))

			var openContext context.Context
			var finishOpen context.CancelFunc
			if testCase.cancelContext {
				openContext, finishOpen = context.WithCancel(context.Background())
				go func() {
					<-openSeen
					finishOpen()
				}()
			} else if testCase.result == nil {
				openContext, finishOpen = context.WithTimeout(
					context.Background(),
					20*time.Millisecond,
				)
			} else {
				openContext, finishOpen = context.WithCancel(context.Background())
			}
			defer finishOpen()

			_, err = session.Events(openContext, SessionEventsOptions{})
			if !errors.Is(err, testCase.wantError) {
				t.Fatalf("open error = %T %v", err, err)
			}
			client.mu.Lock()
			activeRoutes := len(client.streams)
			client.mu.Unlock()
			if activeRoutes != 0 {
				t.Fatalf("active routes after failed open = %d", activeRoutes)
			}
			select {
			case <-cleanupSeen:
			case <-time.After(time.Second):
				t.Fatal("server did not observe bounded stream cleanup")
			}

			stream, err := session.Events(
				context.Background(),
				SessionEventsOptions{},
			)
			if err != nil {
				t.Fatalf("open after quota recovery: %v", err)
			}
			if err := stream.Cancel(context.Background()); err != nil {
				t.Fatalf("cancel recovered stream: %v", err)
			}
			select {
			case <-serverDone:
			case <-time.After(time.Second):
				t.Fatal("server did not finish recovered stream")
			}
		})
	}
}

func TestLatePreAckItemCannotStealFailedOpenCleanup(t *testing.T) {
	previousProcs := runtime.GOMAXPROCS(1)
	defer runtime.GOMAXPROCS(previousProcs)

	type preAckProbe struct {
		request map[string]any
		err     error
	}
	clientSide, serverSide := net.Pipe()
	openSeen := make(chan map[string]any, 1)
	cancelSeen := make(chan map[string]any, 1)
	preAck := make(chan preAckProbe, 1)
	releaseCancelAck := make(chan struct{})
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		openSeen <- open
		cancelRequest := readRequest(t, reader)
		cancelSeen <- cancelRequest
		if err := serverSide.SetReadDeadline(
			time.Now().Add(20 * time.Millisecond),
		); err != nil {
			preAck <- preAckProbe{err: err}
			serverDone <- err
			return
		}
		line, readErr := reader.ReadBytes('\n')
		if err := serverSide.SetReadDeadline(time.Time{}); err != nil {
			preAck <- preAckProbe{err: err}
			serverDone <- err
			return
		}
		probe := preAckProbe{}
		switch {
		case readErr == nil:
			if err := json.Unmarshal(bytes.TrimSpace(line), &probe.request); err != nil {
				probe.err = fmt.Errorf("decode request before cancel acknowledgment: %w", err)
			}
		case len(line) != 0:
			probe.err = fmt.Errorf(
				"partial request before cancel acknowledgment: %q: %w",
				line,
				readErr,
			)
		default:
			var timeout net.Error
			if !errors.As(readErr, &timeout) || !timeout.Timeout() {
				probe.err = fmt.Errorf(
					"probe request before cancel acknowledgment: %w",
					readErr,
				)
			}
		}
		preAck <- probe
		<-releaseCancelAck
		writeSuccess(t, serverSide, cancelRequest["id"], map[string]any{})
		pingRequest := probe.request
		if pingRequest == nil {
			pingRequest = readRequest(t, reader)
		}
		if pingRequest["operation"] != "session.ping" {
			serverDone <- fmt.Errorf(
				"request after failed open = %#v",
				pingRequest["operation"],
			)
			return
		}
		writeSuccess(t, serverSide, pingRequest["id"], map[string]any{
			"alive": true,
			"cursor": map[string]any{
				"generation": "g",
				"revision":   "1",
			},
		})
		serverDone <- nil
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
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	openReturned := make(chan error, 1)
	pingDone := make(chan error, 1)
	go func() {
		_, openErr := session.Events(
			context.Background(),
			SessionEventsOptions{},
		)
		openReturned <- openErr
		_, pingErr := session.Ping(context.Background(), SessionPingOptions{})
		pingDone <- pingErr
	}()

	var open map[string]any
	select {
	case open = <-openSeen:
	case <-time.After(time.Second):
		t.Fatal("server did not observe stream open")
	}
	streamValue, ok := requestParams(t, open)["stream_id"].(string)
	if !ok {
		t.Fatalf("stream id = %#v", requestParams(t, open)["stream_id"])
	}
	streamID := StreamID(streamValue)
	client.mu.Lock()
	route := client.streams[streamID]
	client.mu.Unlock()
	if route == nil {
		t.Fatal("opening stream route is missing")
	}
	deadline := time.Now().Add(time.Second)
	for {
		route.mu.Lock()
		dispatched := route.openDispatched
		if dispatched {
			route.messages = make(chan streamMessage)
		}
		route.mu.Unlock()
		if dispatched {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("stream open was not marked dispatched")
		}
		runtime.Gosched()
	}

	lateItem := streamEnvelope{
		Type:     "stream_item",
		StreamID: streamID,
		Sequence: Decimal(1),
		Item:     json.RawMessage(`{}`),
	}
	client.mu.Lock()
	requestID, ok := open["id"].(string)
	if !ok {
		client.mu.Unlock()
		t.Fatalf("open request id = %#v", open["id"])
	}
	waiter := client.pending[requestID]
	delete(client.pending, requestID)
	if waiter == nil {
		client.mu.Unlock()
		t.Fatal("opening response waiter is missing")
	}
	waiter <- pendingResponse{envelope: responseEnvelope{
		ID:     requestID,
		OK:     true,
		Result: json.RawMessage(`{"stream_id":7}`),
	}}
	close(waiter)
	var terminal streamMessage
	finishedWithoutClientLock := false
	for range 10_000 {
		select {
		case terminal = <-route.messages:
			finishedWithoutClientLock = true
		default:
			runtime.Gosched()
		}
		if finishedWithoutClientLock {
			break
		}
	}
	if finishedWithoutClientLock {
		cleanup := client.deliverStreamLocked(route, lateItem, 1)
		client.mu.Unlock()
		if cleanup {
			go client.cancelStreamBestEffort(route.cancelParams)
		}
	} else {
		client.mu.Unlock()
		select {
		case terminal = <-route.messages:
		case <-time.After(time.Second):
			t.Fatal("failed open did not terminate its route")
		}
		client.deliverStream(lateItem, 1)
	}
	if !errors.Is(terminal.err, ErrProtocol) {
		t.Fatalf("failed-open terminal = %T %v", terminal.err, terminal.err)
	}

	select {
	case cancelRequest := <-cancelSeen:
		if cancelRequest["operation"] != "stream.cancel" {
			t.Fatalf("cleanup operation = %#v", cancelRequest["operation"])
		}
	case <-time.After(time.Second):
		t.Fatal("server did not observe failed-open cleanup")
	}
	var probe preAckProbe
	select {
	case probe = <-preAck:
	case <-time.After(time.Second):
		t.Fatal("server did not finish pre-acknowledgment probe")
	}
	returnedBeforeAck := false
	var openErr error
	select {
	case openErr = <-openReturned:
		returnedBeforeAck = true
	default:
	}
	close(releaseCancelAck)
	if !returnedBeforeAck {
		select {
		case openErr = <-openReturned:
		case <-time.After(time.Second):
			t.Fatal("failed open did not return after cleanup acknowledgment")
		}
	}
	if !errors.Is(openErr, ErrProtocol) {
		t.Fatalf("failed open error = %T %v", openErr, openErr)
	}
	select {
	case pingErr := <-pingDone:
		if pingErr != nil {
			t.Fatalf("request after failed open: %v", pingErr)
		}
	case <-time.After(time.Second):
		t.Fatal("request after failed open did not finish")
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatal(serverErr)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not finish")
	}
	if probe.err != nil {
		t.Fatal(probe.err)
	}
	if returnedBeforeAck {
		t.Fatal("failed stream open returned before cleanup acknowledgment")
	}
	if probe.request != nil {
		t.Fatalf(
			"request overtook failed-open cleanup acknowledgment: %#v",
			probe.request["operation"],
		)
	}
}

func TestRejectedStreamOpenDoesNotCancelOrClose(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol": "cmux.protocol/2",
			"type":     "response",
			"id":       open["id"],
			"ok":       false,
			"error": map[string]any{
				"code":      "session.not_found",
				"message":   "session does not exist",
				"details":   map[string]any{},
				"retryable": false,
			},
		})
		next := readRequest(t, reader)
		if next["operation"] != "session.ping" {
			serverDone <- fmt.Errorf(
				"request after rejected open = %#v",
				next["operation"],
			)
			return
		}
		writeSuccess(t, serverSide, next["id"], map[string]any{
			"alive": true,
			"cursor": map[string]any{
				"generation": "g",
				"revision":   "1",
			},
		})
		serverDone <- nil
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
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	_, err = session.Events(context.Background(), SessionEventsOptions{})
	var rejected *ResourceError
	if !errors.As(err, &rejected) || rejected.Code != "session.not_found" {
		t.Fatalf("rejected open error = %T %v", err, err)
	}
	ping, err := session.Ping(context.Background(), SessionPingOptions{})
	if err != nil || !ping.Alive {
		t.Fatalf("ping after rejected open = %#v, %v", ping, err)
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatal(serverErr)
		}
	case <-time.After(time.Second):
		t.Fatal("connection was not reusable after rejected open")
	}
}

func TestPreCanceledStreamOpenDoesNotSendCleanup(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	defer serverSide.Close()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background()) //nolint:errcheck

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	if _, err := session.Events(ctx, SessionEventsOptions{}); !errors.Is(
		err,
		context.Canceled,
	) {
		t.Fatalf("pre-canceled open error = %T %v", err, err)
	}
	client.mu.Lock()
	activeRoutes := len(client.streams)
	client.mu.Unlock()
	if activeRoutes != 0 {
		t.Fatalf("active routes after pre-canceled open = %d", activeRoutes)
	}

	if err := serverSide.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var probe [1]byte
	if _, err := serverSide.Read(probe[:]); err == nil {
		t.Fatal("pre-canceled stream open wrote a request or cleanup")
	} else if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
		t.Fatalf("pre-canceled stream read error = %T %v", err, err)
	}
}

func TestFullyWrittenStreamOpenWithWriteErrorStillCancels(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	finalWriteError := errors.New("final write reported an error")
	wrappedClient := &fullFrameWriteErrorConn{
		Conn: clientSide,
		err:  finalWriteError,
	}
	cleanupSeen := make(chan map[string]any, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		cleanup := readRequest(t, reader)
		if requestParams(t, cleanup)["stream"] !=
			requestParams(t, open)["stream_id"] {
			t.Errorf("cleanup stream does not match fully written open")
		}
		cleanupSeen <- cleanup
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background()) //nolint:errcheck
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	_, err = session.Events(context.Background(), SessionEventsOptions{})
	if !errors.Is(err, finalWriteError) {
		t.Fatalf("final write error = %T %v", err, err)
	}
	client.mu.Lock()
	activeRoutes := len(client.streams)
	client.mu.Unlock()
	if activeRoutes != 0 {
		t.Fatalf("active routes after final write error = %d", activeRoutes)
	}
	select {
	case cleanup := <-cleanupSeen:
		if cleanup["operation"] != "stream.cancel" {
			t.Fatalf("cleanup operation = %#v", cleanup["operation"])
		}
	case <-time.After(time.Second):
		t.Fatal("fully written open did not trigger bounded cleanup")
	}
}

func TestPartiallyWrittenStreamOpenClosesWithoutCancel(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	partialWriteError := errors.New("partial stream-open write failed")
	wrappedClient := &partialFrameWriteErrorConn{
		Conn: clientSide,
		err:  partialWriteError,
	}
	serverBytes := make(chan []byte, 1)
	go func() {
		defer serverSide.Close()
		received, _ := io.ReadAll(serverSide)
		serverBytes <- received
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	_, err = session.Events(context.Background(), SessionEventsOptions{})
	if !errors.Is(err, partialWriteError) {
		t.Fatalf("partial write error = %T %v", err, err)
	}
	select {
	case received := <-serverBytes:
		if len(received) == 0 || bytes.HasSuffix(received, []byte{'\n'}) {
			t.Fatalf("server received non-partial frame %q", received)
		}
		if bytes.Contains(received, []byte(`"operation":"stream.cancel"`)) {
			t.Fatalf("partial open emitted cancellation: %q", received)
		}
	case <-time.After(time.Second):
		t.Fatal("partial open did not close the connection")
	}
	laterStarted := time.Now()
	_, laterErr := session.Ping(context.Background(), SessionPingOptions{})
	if laterErr == nil {
		t.Fatal("request after partial write unexpectedly succeeded")
	}
	if elapsed := time.Since(laterStarted); elapsed > 100*time.Millisecond {
		t.Fatalf("request after partial write hung for %s", elapsed)
	}
}

func TestPartialSiblingWriteClosesWithoutAppendingStreamCancel(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	partialWriteError := errors.New("partial sibling request write failed")
	wrappedClient := &partialNthWriteErrorConn{
		Conn:        clientSide,
		err:         partialWriteError,
		failOnWrite: 2,
	}
	openSeen := make(chan struct{})
	serverRemainder := make(chan []byte, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		_ = readRequest(t, reader)
		close(openSeen)
		received, _ := io.ReadAll(reader)
		serverRemainder <- received
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		Timeout: 5 * time.Second,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	openDone := make(chan error, 1)
	go func() {
		_, openErr := session.Events(
			context.Background(),
			SessionEventsOptions{},
		)
		openDone <- openErr
	}()
	select {
	case <-openSeen:
	case <-time.After(time.Second):
		t.Fatal("server did not observe the unacknowledged stream open")
	}
	_, pingErr := session.Ping(context.Background(), SessionPingOptions{})
	if !errors.Is(pingErr, partialWriteError) {
		t.Fatalf("partial sibling write error = %T %v", pingErr, pingErr)
	}
	select {
	case openErr := <-openDone:
		if openErr == nil {
			t.Fatal("unacknowledged open survived poisoned transport")
		}
	case <-time.After(time.Second):
		t.Fatal("unacknowledged open did not finish after disconnect")
	}
	select {
	case received := <-serverRemainder:
		if len(received) == 0 || bytes.HasSuffix(received, []byte{'\n'}) {
			t.Fatalf("server received non-partial sibling frame %q", received)
		}
		if bytes.Contains(received, []byte(`"operation":"stream.cancel"`)) {
			t.Fatalf("partial frame was followed by cancellation: %q", received)
		}
	case <-time.After(time.Second):
		t.Fatal("partial sibling write did not close the connection")
	}
}

func TestReaderFailureDoesNotAppendCancelAfterPartialSiblingWrite(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	partialWriteError := errors.New("blocked partial sibling request write failed")
	wrappedClient := &blockedPartialNthWriteErrorConn{
		Conn:           clientSide,
		err:            partialWriteError,
		failOnWrite:    2,
		partialStarted: make(chan struct{}),
		partialWritten: make(chan struct{}),
		release:        make(chan struct{}),
	}
	openSeen := make(chan struct{})
	serverRemainder := make(chan []byte, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		_ = readRequest(t, reader)
		close(openSeen)
		<-wrappedClient.partialStarted
		partial := make([]byte, 4096)
		count, readErr := reader.Read(partial)
		if readErr != nil {
			t.Errorf("read partial sibling request: %v", readErr)
			return
		}
		if _, writeErr := serverSide.Write([]byte(
			`{"protocol":"not-cmux","type":"response"}` + "\n",
		)); writeErr != nil {
			t.Errorf("write invalid protocol response: %v", writeErr)
			return
		}
		remainder, _ := io.ReadAll(reader)
		serverRemainder <- append(partial[:count:count], remainder...)
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		Timeout: 5 * time.Second,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	openDone := make(chan error, 1)
	go func() {
		_, openErr := session.Events(
			context.Background(),
			SessionEventsOptions{},
		)
		openDone <- openErr
	}()
	select {
	case <-openSeen:
	case <-time.After(time.Second):
		t.Fatal("server did not observe the unacknowledged stream open")
	}
	pingDone := make(chan error, 1)
	go func() {
		_, pingErr := session.Ping(context.Background(), SessionPingOptions{})
		pingDone <- pingErr
	}()
	select {
	case <-wrappedClient.partialWritten:
	case <-time.After(time.Second):
		t.Fatal("sibling request did not partially write")
	}
	deadline := time.Now().Add(time.Second)
	for {
		client.mu.Lock()
		closed := client.closed
		client.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("reader failure did not start connection shutdown")
		}
		runtime.Gosched()
	}
	close(wrappedClient.release)
	select {
	case pingErr := <-pingDone:
		if !errors.Is(pingErr, partialWriteError) {
			t.Fatalf("partial sibling write error = %T %v", pingErr, pingErr)
		}
	case <-time.After(time.Second):
		t.Fatal("partial sibling request did not finish")
	}
	select {
	case openErr := <-openDone:
		if !errors.Is(openErr, ErrProtocol) {
			t.Fatalf("unacknowledged open error = %T %v", openErr, openErr)
		}
	case <-time.After(time.Second):
		t.Fatal("unacknowledged open did not finish")
	}
	select {
	case received := <-serverRemainder:
		if count := bytes.Count(
			received,
			[]byte(`"operation":"stream.cancel"`),
		); count != 0 {
			t.Fatalf("partial frame was followed by %d cancellation(s): %q", count, received)
		}
		if len(received) == 0 || bytes.HasSuffix(received, []byte{'\n'}) {
			t.Fatalf("server received non-partial sibling frame %q", received)
		}
	case <-time.After(time.Second):
		t.Fatal("connection did not close after concurrent failures")
	}
}

func TestStreamOpenTransportFailureSendsCleanupBeforeDisconnect(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cleanupSeen := make(chan map[string]any, 1)
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol": "not-cmux",
			"type":     "response",
			"id":       open["id"],
			"ok":       true,
			"result": map[string]any{
				"stream_id": requestParams(t, open)["stream_id"],
			},
		})
		cleanupSeen <- readRequest(t, reader)
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
	_, err = session.Events(context.Background(), SessionEventsOptions{})
	if !errors.Is(err, ErrProtocol) {
		t.Fatalf("transport protocol failure = %T %v", err, err)
	}
	client.mu.Lock()
	activeRoutes := len(client.streams)
	client.mu.Unlock()
	if activeRoutes != 0 {
		t.Fatalf("active routes after transport failure = %d", activeRoutes)
	}
	select {
	case cleanup := <-cleanupSeen:
		if cleanup["operation"] != "stream.cancel" {
			t.Fatalf("cleanup operation = %#v", cleanup["operation"])
		}
		params := requestParams(t, cleanup)
		if params["machine"] != string(testMachineID) ||
			params["session"] != string(testSessionID) ||
			params["stream"] == nil {
			t.Fatalf("cleanup route = %#v", params)
		}
	case <-time.After(time.Second):
		t.Fatal("transport failure did not send bounded cleanup before disconnect")
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("transport-failure server did not finish")
	}
}

func TestTransportFailureWaitsForBlockedDispatchMarker(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	wrappedClient := &blockedFullWriteReturnConn{
		Conn:      clientSide,
		delivered: make(chan struct{}),
		release:   make(chan struct{}),
	}
	cleanupSeen := make(chan map[string]any, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol": "not-cmux",
			"type":     "response",
			"id":       open["id"],
			"ok":       true,
			"result": map[string]any{
				"stream_id": requestParams(t, open)["stream_id"],
			},
		})
		cleanupSeen <- readRequest(t, reader)
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	openDone := make(chan error, 1)
	go func() {
		_, openErr := session.Events(
			context.Background(),
			SessionEventsOptions{},
		)
		openDone <- openErr
	}()
	select {
	case <-wrappedClient.delivered:
	case <-time.After(time.Second):
		t.Fatal("stream-open frame was not delivered")
	}
	deadline := time.Now().Add(time.Second)
	for {
		client.mu.Lock()
		closed := client.closed
		client.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("reader failure did not close logical connection")
		}
		runtime.Gosched()
	}
	close(wrappedClient.release)
	select {
	case openErr := <-openDone:
		if !errors.Is(openErr, ErrProtocol) {
			t.Fatalf("blocked-dispatch open error = %T %v", openErr, openErr)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked-dispatch open did not finish")
	}
	select {
	case cleanup := <-cleanupSeen:
		if cleanup["operation"] != "stream.cancel" {
			t.Fatalf("cleanup operation = %#v", cleanup["operation"])
		}
	case <-time.After(time.Second):
		t.Fatal("transport failure missed the dispatch marker")
	}
}

func TestFailedStreamOpenCleanupTimeoutClosesConnection(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cleanupSeen := make(chan struct{})
	disconnected := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": 7,
		})
		cleanup := readRequest(t, reader)
		if cleanup["operation"] != "stream.cancel" {
			disconnected <- fmt.Errorf(
				"cleanup operation = %#v",
				cleanup["operation"],
			)
			return
		}
		close(cleanupSeen)
		if err := serverSide.SetReadDeadline(
			time.Now().Add(2 * time.Second),
		); err != nil {
			disconnected <- err
			return
		}
		_, err := reader.ReadByte()
		if errors.Is(err, io.EOF) {
			disconnected <- nil
			return
		}
		disconnected <- fmt.Errorf(
			"connection remained open after cleanup timeout: %w",
			err,
		)
	}()

	client, err := NewClient(context.Background(), ClientOptions{
		Timeout: 5 * time.Second,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	started := time.Now()
	_, err = session.Events(context.Background(), SessionEventsOptions{})
	if !errors.Is(err, ErrProtocol) {
		t.Fatalf("opening error = %T %v", err, err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("failed cleanup was not bounded: %s", elapsed)
	}
	select {
	case <-cleanupSeen:
	default:
		t.Fatal("failed-open cancellation was not dispatched")
	}
	select {
	case disconnectErr := <-disconnected:
		if disconnectErr != nil {
			t.Fatal(disconnectErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cleanup timeout did not close the connection")
	}

	laterStarted := time.Now()
	_, laterErr := session.Ping(context.Background(), SessionPingOptions{})
	if laterErr == nil {
		t.Fatal("request after cleanup timeout unexpectedly succeeded")
	}
	if elapsed := time.Since(laterStarted); elapsed > 100*time.Millisecond {
		t.Fatalf("request after cleanup timeout hung for %s", elapsed)
	}
}

func TestResponseEnvelopesRequireExactCanonicalShape(t *testing.T) {
	valid := map[string]string{
		"success": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"request-1","ok":true,"result":null}`,
		"failure": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"request-1","ok":false,"error":{` +
			`"code":"resource.failed","message":"failed",` +
			`"details":null,"retryable":false}}`,
	}
	for name, raw := range valid {
		t.Run("valid "+name, func(t *testing.T) {
			if _, err := decodeResponseEnvelope(json.RawMessage(raw)); err != nil {
				t.Fatalf("valid response rejected: %v", err)
			}
		})
	}

	structuredError := `{"code":"resource.failed","message":"failed",` +
		`"details":{},"retryable":false}`
	invalid := map[string]string{
		"unknown top-level field": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":true,` +
			`"result":{},"extra":true}`,
		"missing protocol": `{"type":"response","id":"request-1",` +
			`"ok":true,"result":{}}`,
		"null protocol": `{"protocol":null,"type":"response",` +
			`"id":"request-1","ok":true,"result":{}}`,
		"wrong type": `{"protocol":"cmux.protocol/2","type":"stream_end",` +
			`"id":"request-1","ok":true,"result":{}}`,
		"missing id": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"ok":true,"result":{}}`,
		"empty id": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"","ok":true,"result":{}}`,
		"missing ok": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"request-1","result":{}}`,
		"null ok": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"request-1","ok":null,"result":{}}`,
		"success missing result": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":true}`,
		"success with error": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":true,` +
			`"result":{},"error":` + structuredError + `}`,
		"failure missing error": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":false}`,
		"failure with result": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":false,` +
			`"result":{},"error":` + structuredError + `}`,
		"null error": `{"protocol":"cmux.protocol/2","type":"response",` +
			`"id":"request-1","ok":false,"error":null}`,
		"error unknown field": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":false,"error":{` +
			`"code":"resource.failed","message":"failed","details":{},` +
			`"retryable":false,"extra":true}}`,
		"error missing field": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":false,"error":{` +
			`"code":"resource.failed","message":"failed","retryable":false}}`,
		"error null retryable": `{"protocol":"cmux.protocol/2",` +
			`"type":"response","id":"request-1","ok":false,"error":{` +
			`"code":"resource.failed","message":"failed","details":{},` +
			`"retryable":null}}`,
	}
	for name, raw := range invalid {
		t.Run(name, func(t *testing.T) {
			_, err := decodeResponseEnvelope(json.RawMessage(raw))
			if !errors.Is(err, ErrProtocol) {
				t.Fatalf("invalid response error = %T %v", err, err)
			}
		})
	}
}

func TestStreamEnvelopesRequireExactCanonicalShape(t *testing.T) {
	const streamID = "stream_00000000000000000000000000000001"
	valid := map[string]struct {
		envelopeType string
		raw          string
	}{
		"item without cursor": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"0","item":null}`,
		},
		"item with cursor": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"cursor":{"generation":"g","revision":"2"},"item":{}}`,
		},
		"canceled end": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled",` +
				`"cursor":{"generation":"g","revision":"2"},` +
				`"recovery":"reopen"}`,
		},
		"error end": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"error","error":{` +
				`"code":"stream.failed","message":"failed",` +
				`"details":null,"retryable":true}}`,
		},
	}
	for name, testCase := range valid {
		t.Run("valid "+name, func(t *testing.T) {
			if _, err := decodeStreamEnvelope(
				json.RawMessage(testCase.raw),
				testCase.envelopeType,
			); err != nil {
				t.Fatalf("valid stream envelope rejected: %v", err)
			}
		})
	}

	invalid := map[string]struct {
		envelopeType string
		raw          string
	}{
		"item unknown top-level field": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"item":{},"extra":true}`,
		},
		"item missing stream id": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"sequence":"1","item":{}}`,
		},
		"item number sequence": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":1,"item":{}}`,
		},
		"item missing item": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1"}`,
		},
		"item null cursor": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"cursor":null,"item":{}}`,
		},
		"item cursor missing revision": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"cursor":{"generation":"g"},"item":{}}`,
		},
		"item cursor number revision": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"cursor":{"generation":"g","revision":2},"item":{}}`,
		},
		"item cursor unknown field": {
			envelopeType: "stream_item",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_item",` +
				`"stream_id":"` + streamID + `","sequence":"1",` +
				`"cursor":{"generation":"g","revision":"2","extra":true},` +
				`"item":{}}`,
		},
		"end unknown top-level field": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled",` +
				`"extra":true}`,
		},
		"end missing reason": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `"}`,
		},
		"end unknown reason": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"future"}`,
		},
		"end null cursor": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled",` +
				`"cursor":null}`,
		},
		"end strict cursor": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled",` +
				`"cursor":{"generation":"g","revision":"2","extra":true}}`,
		},
		"end null recovery": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled",` +
				`"recovery":null}`,
		},
		"end null error": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"error","error":null}`,
		},
		"end error unknown field": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"error","error":{` +
				`"code":"stream.failed","message":"failed","details":{},` +
				`"retryable":true,"extra":true}}`,
		},
		"end error missing field": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"error","error":{` +
				`"code":"stream.failed","message":"failed","retryable":true}}`,
		},
		"error reason missing error": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"error"}`,
		},
		"non-error reason with error": {
			envelopeType: "stream_end",
			raw: `{"protocol":"cmux.protocol/2","type":"stream_end",` +
				`"stream_id":"` + streamID + `","reason":"canceled","error":{` +
				`"code":"stream.failed","message":"failed",` +
				`"details":{},"retryable":true}}`,
		},
	}
	for name, testCase := range invalid {
		t.Run(name, func(t *testing.T) {
			_, err := decodeStreamEnvelope(
				json.RawMessage(testCase.raw),
				testCase.envelopeType,
			)
			if !errors.Is(err, ErrProtocol) {
				t.Fatalf("invalid stream envelope error = %T %v", err, err)
			}
		})
	}
}

func TestTypedStreamEndAndCancellation(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	wrappedClient := &blockedFullWriteReturnConn{
		Conn:      clientSide,
		delivered: make(chan struct{}),
		release:   make(chan struct{}),
	}
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
			"protocol":  "cmux.protocol/2",
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
			"protocol":  "cmux.protocol/2",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "error",
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
			return wrappedClient, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	type openResult struct {
		stream *Stream[SessionEvent]
		err    error
	}
	openDone := make(chan openResult, 1)
	go func() {
		stream, openErr := session.Events(context.Background(), SessionEventsOptions{})
		openDone <- openResult{stream: stream, err: openErr}
	}()
	select {
	case <-wrappedClient.delivered:
	case <-time.After(time.Second):
		t.Fatal("stream-open frame was not delivered")
	}
	deadline := time.Now().Add(time.Second)
	for {
		client.mu.Lock()
		closed := client.closed
		client.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("client did not observe EOF after the complete stream")
		}
		runtime.Gosched()
	}
	close(wrappedClient.release)
	var stream *Stream[SessionEvent]
	select {
	case result := <-openDone:
		stream, err = result.stream, result.err
	case <-time.After(time.Second):
		t.Fatal("stream open did not finish after releasing the write")
	}
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
	if !errors.As(err, &end) || end.Reason != "error" ||
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

func TestAcknowledgedStreamOpenSurvivesTerminalTransportClose(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	releaseWrite := make(chan struct{})
	heldClientSide := &heldWriteReturnConn{
		Conn:    clientSide,
		release: releaseWrite,
		timeout: 5 * time.Second,
	}
	go func() {
		defer serverSide.Close()
		open := readRequest(t, bufio.NewReader(serverSide))
		streamID := requestParams(t, open)["stream_id"]
		var batch bytes.Buffer
		encoder := json.NewEncoder(&batch)
		for _, envelope := range []map[string]any{
			{
				"protocol": "cmux.protocol/2",
				"type":     "response",
				"id":       open["id"],
				"ok":       true,
				"result":   map[string]any{"stream_id": streamID},
			},
			{
				"protocol":  "cmux.protocol/2",
				"type":      "stream_end",
				"stream_id": streamID,
				"reason":    "completed",
			},
		} {
			if err := encoder.Encode(envelope); err != nil {
				t.Errorf("encode server batch: %v", err)
				return
			}
		}
		if _, err := serverSide.Write(batch.Bytes()); err != nil {
			t.Errorf("write server batch: %v", err)
		}
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return heldClientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		<-client.done
		close(releaseWrite)
	}()
	session := client.Machine(SelectID(testMachineID)).Session(SelectID(testSessionID))
	stream, err := session.Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open acknowledged stream: %v", err)
	}
	_, err = stream.Recv(context.Background())
	var end *StreamEndError
	if !errors.As(err, &end) || end.Reason != "completed" {
		t.Fatalf("stream end = %T %#v", err, err)
	}
}

type heldWriteReturnConn struct {
	net.Conn
	release <-chan struct{}
	timeout time.Duration
}

func (c *heldWriteReturnConn) Write(value []byte) (int, error) {
	count, err := c.Conn.Write(value)
	if err == nil && count == len(value) {
		select {
		case <-c.release:
		case <-time.After(c.timeout):
			return count, context.DeadlineExceeded
		}
	}
	return count, err
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
			"protocol":  "cmux.protocol/2",
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

func TestExplicitCancelWaitsForResponseAndEndInEitherOrder(t *testing.T) {
	for _, responseFirst := range []bool{false, true} {
		name := "end before response"
		if responseFirst {
			name = "response before end"
		}
		t.Run(name, func(t *testing.T) {
			clientSide, serverSide := net.Pipe()
			readyToCancel := make(chan struct{})
			firstConfirmation := make(chan struct{})
			releaseSecond := make(chan struct{})
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
				writeEnvelope(t, serverSide, map[string]any{
					"protocol":  "cmux.protocol/2",
					"type":      "stream_item",
					"stream_id": streamID,
					"sequence":  "1",
					"item":      map[string]any{"kind": "future-session-item"},
				})
				close(readyToCancel)

				cancel := readRequest(t, reader)
				writeEnd := func() {
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": streamID,
						"reason":    "canceled",
					})
				}
				writeResponse := func() {
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
				}
				if responseFirst {
					writeResponse()
				} else {
					writeEnd()
				}
				close(firstConfirmation)
				<-releaseSecond
				if responseFirst {
					writeEnd()
				} else {
					writeResponse()
				}
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
			stream, err := client.Machine(SelectID(testMachineID)).
				Session(SelectID(testSessionID)).
				Events(context.Background(), SessionEventsOptions{})
			if err != nil {
				t.Fatalf("open stream: %v", err)
			}
			select {
			case <-readyToCancel:
			case <-time.After(time.Second):
				t.Fatal("server did not queue stale stream item")
			}
			cancelDone := make(chan error, 1)
			go func() {
				cancelDone <- stream.Cancel(context.Background())
			}()
			select {
			case <-firstConfirmation:
			case <-time.After(time.Second):
				close(releaseSecond)
				t.Fatal("server did not send first cancellation confirmation")
			}
			select {
			case cancelErr := <-cancelDone:
				close(releaseSecond)
				t.Fatalf(
					"cancel returned after only one confirmation: %v",
					cancelErr,
				)
			default:
			}
			close(releaseSecond)
			select {
			case cancelErr := <-cancelDone:
				if cancelErr != nil {
					t.Fatalf("cancel after both confirmations: %v", cancelErr)
				}
			case <-time.After(time.Second):
				t.Fatal("cancel did not return after both confirmations")
			}
			if end := stream.End(); end == nil || end.Reason != "canceled" {
				t.Fatalf("cancel end = %#v", end)
			}
			select {
			case <-serverDone:
			case <-time.After(time.Second):
				t.Fatal("server did not finish cancellation")
			}
		})
	}
}

func TestExplicitCancelInvalidConfirmationFailsClosedOnce(t *testing.T) {
	testCases := []struct {
		name      string
		mode      string
		wantError error
	}{
		{name: "missing end", mode: "missing_end", wantError: context.DeadlineExceeded},
		{name: "wrong end id", mode: "wrong_id", wantError: context.DeadlineExceeded},
		{name: "wrong end reason", mode: "wrong_reason", wantError: ErrProtocol},
		{name: "malformed end", mode: "malformed_end", wantError: ErrProtocol},
		{name: "malformed stale item", mode: "malformed_item", wantError: ErrProtocol},
		{
			name: "malformed stale item after end", mode: "post_end_malformed_item",
			wantError: ErrProtocol,
		},
		{
			name: "valid stale item after end", mode: "post_end_valid_item",
			wantError: ErrProtocol,
		},
		{name: "response extra field", mode: "response_extra", wantError: ErrProtocol},
		{
			name: "response result and error", mode: "response_both",
			wantError: ErrProtocol,
		},
		{name: "response null result", mode: "response_null", wantError: ErrProtocol},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			clientSide, serverSide := net.Pipe()
			serverDone := make(chan error, 1)
			go func() {
				defer serverSide.Close()
				reader := bufio.NewReader(serverSide)
				open := readRequest(t, reader)
				streamID := requestParams(t, open)["stream_id"]
				writeSuccess(t, serverSide, open["id"], map[string]any{
					"stream_id": streamID,
				})
				cancel := readRequest(t, reader)
				errorBody := map[string]any{
					"code":      "cancel.failed",
					"message":   "failed",
					"details":   map[string]any{},
					"retryable": false,
				}
				switch testCase.mode {
				case "missing_end":
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
				case "wrong_id":
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": "stream_ffffffffffffffffffffffffffffffff",
						"reason":    "canceled",
					})
				case "wrong_reason":
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": streamID,
						"reason":    "completed",
					})
				case "malformed_end":
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": streamID,
						"reason":    "canceled",
						"extra":     true,
					})
				case "malformed_item":
					writeSuccess(t, serverSide, cancel["id"], map[string]any{})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_item",
						"stream_id": streamID,
						"sequence":  "1",
						"item":      map[string]any{"kind": "snapshot"},
					})
				case "post_end_malformed_item":
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": streamID,
						"reason":    "canceled",
					})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_item",
						"stream_id": streamID,
						"sequence":  "1",
						"item":      map[string]any{"kind": "snapshot"},
					})
					writeSuccessOrClosed(t, serverSide, cancel["id"])
				case "post_end_valid_item":
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_end",
						"stream_id": streamID,
						"reason":    "canceled",
					})
					writeEnvelope(t, serverSide, map[string]any{
						"protocol":  "cmux.protocol/2",
						"type":      "stream_item",
						"stream_id": streamID,
						"sequence":  "1",
						"item": map[string]any{
							"kind":              "delta",
							"cursor":            map[string]any{"generation": "g", "revision": "2"},
							"previous_revision": "1",
							"revision":          "2",
							"changes":           []any{},
						},
					})
					writeSuccessOrClosed(t, serverSide, cancel["id"])
				case "response_extra":
					writeEnvelope(t, serverSide, map[string]any{
						"protocol": "cmux.protocol/2",
						"type":     "response",
						"id":       cancel["id"],
						"ok":       true,
						"result":   map[string]any{},
						"extra":    true,
					})
				case "response_both":
					writeEnvelope(t, serverSide, map[string]any{
						"protocol": "cmux.protocol/2",
						"type":     "response",
						"id":       cancel["id"],
						"ok":       true,
						"result":   map[string]any{},
						"error":    errorBody,
					})
				case "response_null":
					writeEnvelope(t, serverSide, map[string]any{
						"protocol": "cmux.protocol/2",
						"type":     "response",
						"id":       cancel["id"],
						"ok":       true,
						"result":   nil,
					})
				}

				if err := serverSide.SetReadDeadline(
					time.Now().Add(time.Second),
				); err != nil {
					if errors.Is(err, io.ErrClosedPipe) {
						serverDone <- nil
						return
					}
					serverDone <- err
					return
				}
				value, err := reader.ReadByte()
				if errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe) {
					serverDone <- nil
					return
				}
				if err == nil {
					serverDone <- fmt.Errorf(
						"duplicate cancellation began with byte %q",
						value,
					)
					return
				}
				serverDone <- fmt.Errorf("waiting for fail-close: %w", err)
			}()

			client, err := NewClient(context.Background(), ClientOptions{
				Timeout: 30 * time.Millisecond,
				DialContext: func(context.Context, string, string) (net.Conn, error) {
					return clientSide, nil
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close(context.Background()) //nolint:errcheck
			stream, err := client.Machine(SelectID(testMachineID)).
				Session(SelectID(testSessionID)).
				Events(context.Background(), SessionEventsOptions{})
			if err != nil {
				t.Fatalf("open stream: %v", err)
			}
			cancelStart := make(chan struct{})
			cancelErrors := make(chan error, 2)
			for range 2 {
				go func() {
					<-cancelStart
					cancelErrors <- stream.Cancel(context.Background())
				}()
			}
			close(cancelStart)
			var firstError, secondError error
			select {
			case firstError = <-cancelErrors:
			case <-time.After(time.Second):
				t.Fatal("first concurrent cancel did not finish")
			}
			select {
			case secondError = <-cancelErrors:
			case <-time.After(time.Second):
				t.Fatal("second concurrent cancel did not finish")
			}
			if !errors.Is(firstError, testCase.wantError) {
				t.Fatalf("first cancel error = %T %v", firstError, firstError)
			}
			if !errors.Is(secondError, testCase.wantError) {
				t.Fatalf("second cancel error = %T %v", secondError, secondError)
			}
			if firstError != secondError {
				t.Fatalf(
					"repeated cancel error changed from %p to %p",
					firstError,
					secondError,
				)
			}
			preCanceled, cancelPreCanceled := context.WithCancel(context.Background())
			cancelPreCanceled()
			if repeatedError := stream.Cancel(preCanceled); repeatedError != firstError {
				t.Fatalf("repeated cancel error = %T %v", repeatedError, repeatedError)
			}
			select {
			case serverErr := <-serverDone:
				if serverErr != nil {
					t.Fatal(serverErr)
				}
			case <-time.After(time.Second):
				t.Fatal("invalid cancellation confirmation did not close connection")
			}
		})
	}
}

func TestFirstExplicitCancelCallerOwnsCancellationContext(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	serverRelease := make(chan struct{})
	var releaseServer sync.Once
	defer releaseServer.Do(func() { close(serverRelease) })
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
		cancel := readRequest(t, reader)
		if cancel["operation"] != "stream.cancel" {
			serverDone <- fmt.Errorf("cancel operation = %#v", cancel["operation"])
			return
		}
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/2",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "canceled",
		})
		writeSuccess(t, serverSide, cancel["id"], map[string]any{})
		<-serverRelease
		serverDone <- nil
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
	stream, err := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}

	select {
	case <-client.writer:
	case <-time.After(time.Second):
		t.Fatal("could not pause cancellation dispatch")
	}
	writerHeld := true
	defer func() {
		if writerHeld {
			client.writer <- struct{}{}
		}
	}()
	ownerDone := make(chan error, 1)
	go func() {
		ownerDone <- stream.Cancel(context.Background())
	}()
	deadline := time.Now().Add(time.Second)
	for {
		stream.mu.Lock()
		started := stream.cancelStarted
		stream.mu.Unlock()
		if started {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first cancellation caller did not claim ownership")
		}
		runtime.Gosched()
	}

	preCanceled, cancelPreCanceled := context.WithCancel(context.Background())
	cancelPreCanceled()
	lateDone := make(chan error, 1)
	go func() {
		lateDone <- stream.Cancel(preCanceled)
	}()
	select {
	case lateError := <-lateDone:
		t.Fatalf("late pre-canceled caller replaced owner: %v", lateError)
	case <-time.After(20 * time.Millisecond):
	}
	client.writer <- struct{}{}
	writerHeld = false

	select {
	case ownerError := <-ownerDone:
		if ownerError != nil {
			t.Fatalf("owner cancellation: %v", ownerError)
		}
	case <-time.After(time.Second):
		t.Fatal("owner cancellation did not finish")
	}
	select {
	case lateError := <-lateDone:
		if lateError != nil {
			t.Fatalf("late cancellation result: %v", lateError)
		}
	case <-time.After(time.Second):
		t.Fatal("late cancellation did not receive cached result")
	}
	releaseServer.Do(func() { close(serverRelease) })
	select {
	case serverError := <-serverDone:
		if serverError != nil {
			t.Fatal(serverError)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not finish")
	}
}

func TestExplicitCancelStaleItemDripUsesOneTotalDeadline(t *testing.T) {
	const cancelTimeout = 40 * time.Millisecond
	clientSide, serverSide := net.Pipe()
	var sentItems atomic.Int64
	serverDone := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
		cancel := readRequest(t, reader)
		writeSuccess(t, serverSide, cancel["id"], map[string]any{})
		encoded, err := json.Marshal(map[string]any{
			"protocol":  "cmux.protocol/2",
			"type":      "stream_item",
			"stream_id": streamID,
			"sequence":  "1",
			"item":      map[string]any{"kind": "future-session-item"},
		})
		if err != nil {
			serverDone <- err
			return
		}
		encoded = append(encoded, '\n')
		if err := serverSide.SetWriteDeadline(
			time.Now().Add(time.Second),
		); err != nil {
			serverDone <- err
			return
		}
		for {
			if _, err := serverSide.Write(encoded); err != nil {
				serverDone <- nil
				return
			}
			sentItems.Add(1)
			time.Sleep(2 * time.Millisecond)
		}
	}()

	client, err := NewClient(context.Background(), ClientOptions{
		Timeout: cancelTimeout,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background()) //nolint:errcheck
	stream, err := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	started := time.Now()
	firstError := stream.Cancel(context.Background())
	elapsed := time.Since(started)
	if !errors.Is(firstError, context.DeadlineExceeded) {
		t.Fatalf("cancel drip error = %T %v", firstError, firstError)
	}
	if elapsed > 250*time.Millisecond {
		t.Fatalf("stale items reset cancellation deadline: %s", elapsed)
	}
	if sentItems.Load() < 2 {
		t.Fatalf("server sent only %d stale items", sentItems.Load())
	}
	if secondError := stream.Cancel(context.Background()); secondError != firstError {
		t.Fatalf("repeated cancel error = %T %v", secondError, secondError)
	}
	select {
	case serverErr := <-serverDone:
		if serverErr != nil {
			t.Fatal(serverErr)
		}
	case <-time.After(time.Second):
		t.Fatal("stale item deadline did not close the connection")
	}
}

func TestPreCanceledExplicitCancelCanBeRetried(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cancelSeen := make(chan struct{})
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
		cancel := readRequest(t, reader)
		close(cancelSeen)
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/2",
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
	stream, err := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := stream.Cancel(canceled); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled explicit cancel = %T %v", err, err)
	}
	select {
	case <-cancelSeen:
		t.Fatal("pre-canceled explicit cancel reached the server")
	case <-time.After(50 * time.Millisecond):
	}
	if err := stream.Cancel(context.Background()); err != nil {
		t.Fatalf("retry explicit cancel: %v", err)
	}
	select {
	case <-cancelSeen:
	case <-time.After(time.Second):
		t.Fatal("retried explicit cancel did not reach the server")
	}
}

func TestExplicitCancelTimeoutClosesConnection(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	cancelSeen := make(chan struct{})
	disconnected := make(chan error, 1)
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})
		cancel := readRequest(t, reader)
		if cancel["operation"] != "stream.cancel" {
			disconnected <- fmt.Errorf(
				"cancel operation = %#v",
				cancel["operation"],
			)
			return
		}
		close(cancelSeen)
		if err := serverSide.SetReadDeadline(
			time.Now().Add(time.Second),
		); err != nil {
			disconnected <- err
			return
		}
		_, err := reader.ReadByte()
		if errors.Is(err, io.EOF) {
			disconnected <- nil
			return
		}
		disconnected <- fmt.Errorf(
			"connection remained open after cancel timeout: %w",
			err,
		)
	}()
	client, err := NewClient(context.Background(), ClientOptions{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return clientSide, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	session := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID))
	stream, err := session.Events(
		context.Background(),
		SessionEventsOptions{},
	)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	cancelContext, cancel := context.WithTimeout(
		context.Background(),
		20*time.Millisecond,
	)
	defer cancel()
	if err := stream.Cancel(cancelContext); !errors.Is(
		err,
		context.DeadlineExceeded,
	) {
		t.Fatalf("cancel timeout = %T %v", err, err)
	}
	select {
	case <-cancelSeen:
	case <-time.After(time.Second):
		t.Fatal("cancel request was not dispatched")
	}
	select {
	case disconnectErr := <-disconnected:
		if disconnectErr != nil {
			t.Fatal(disconnectErr)
		}
	case <-time.After(time.Second):
		t.Fatal("cancel timeout did not close the connection")
	}
	started := time.Now()
	_, laterErr := session.Ping(context.Background(), SessionPingOptions{})
	if laterErr == nil {
		t.Fatal("request after cancel timeout unexpectedly succeeded")
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("request after cancel timeout hung for %s", elapsed)
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

func TestOverflowAndExplicitCancelSendOneCleanup(t *testing.T) {
	clientSide, serverSide := net.Pipe()
	serverResult := make(chan error, 1)
	overflowDone := make(chan struct{})
	go func() {
		defer serverSide.Close()
		reader := bufio.NewReader(serverSide)
		open := readRequest(t, reader)
		streamID := requestParams(t, open)["stream_id"]
		writeSuccess(t, serverSide, open["id"], map[string]any{
			"stream_id": streamID,
		})

		cancel := readRequest(t, reader)
		if cancel["operation"] != "stream.cancel" {
			serverResult <- fmt.Errorf(
				"cleanup operation = %#v",
				cancel["operation"],
			)
			return
		}
		select {
		case <-overflowDone:
		case <-time.After(time.Second):
			serverResult <- fmt.Errorf("overflow delivery did not finish before cancellation response")
			return
		}
		writeEnvelope(t, serverSide, map[string]any{
			"protocol":  "cmux.protocol/2",
			"type":      "stream_end",
			"stream_id": streamID,
			"reason":    "canceled",
		})
		writeSuccess(t, serverSide, cancel["id"], map[string]any{})

		if err := serverSide.SetReadDeadline(
			time.Now().Add(100 * time.Millisecond),
		); err != nil {
			serverResult <- err
			return
		}
		var extra map[string]any
		decodeErr := json.NewDecoder(serverSide).Decode(&extra)
		if decodeErr == nil {
			serverResult <- fmt.Errorf("duplicate cleanup request = %#v", extra)
			return
		}
		if timeout, ok := decodeErr.(net.Error); ok && timeout.Timeout() {
			serverResult <- nil
			return
		}
		serverResult <- fmt.Errorf(
			"checking for duplicate cleanup: %w",
			decodeErr,
		)
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
	stream, err := client.Machine(SelectID(testMachineID)).
		Session(SelectID(testSessionID)).
		Events(context.Background(), SessionEventsOptions{})
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	for range MaxStreamQueueMessages {
		if !stream.route.deliver(streamMessage{
			envelope: streamEnvelope{
				Type:     "stream_item",
				StreamID: stream.ID(),
				Item:     json.RawMessage(`{"kind":"future-session-item"}`),
			},
			size: 1,
		}) {
			t.Fatal("stream queue filled before its documented bound")
		}
	}

	start := make(chan struct{})
	cancelDone := make(chan error, 1)
	go func() {
		<-start
		cancelDone <- stream.Cancel(context.Background())
	}()
	go func() {
		defer close(overflowDone)
		<-start
		client.deliverStream(streamEnvelope{
			Type:     "stream_item",
			StreamID: stream.ID(),
			Item:     json.RawMessage(`{"kind":"future-session-item"}`),
		}, 1)
	}()
	close(start)
	select {
	case err := <-cancelDone:
		if err != nil {
			t.Fatalf("explicit cancel: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("explicit cancel did not finish")
	}
	select {
	case <-overflowDone:
	case <-time.After(time.Second):
		t.Fatal("overflow delivery did not finish")
	}
	select {
	case err := <-serverResult:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not observe bounded cleanup")
	}
}

type fullFrameWriteErrorConn struct {
	net.Conn
	err      error
	injected atomic.Bool
}

type partialFrameWriteErrorConn struct {
	net.Conn
	err      error
	injected atomic.Bool
}

type blockedFullWriteReturnConn struct {
	net.Conn
	delivered chan struct{}
	release   chan struct{}
	blocked   atomic.Bool
}

func (c *blockedFullWriteReturnConn) Write(value []byte) (int, error) {
	count, err := c.Conn.Write(value)
	if err == nil &&
		count == len(value) &&
		c.blocked.CompareAndSwap(false, true) {
		close(c.delivered)
		<-c.release
	}
	return count, err
}

type partialNthWriteErrorConn struct {
	net.Conn
	err         error
	failOnWrite uint32
	writeCount  atomic.Uint32
}

type blockedPartialNthWriteErrorConn struct {
	net.Conn
	err            error
	failOnWrite    uint32
	writeCount     atomic.Uint32
	partialStarted chan struct{}
	partialWritten chan struct{}
	release        chan struct{}
}

func (c *blockedPartialNthWriteErrorConn) Write(value []byte) (int, error) {
	if c.writeCount.Add(1) != c.failOnWrite {
		return c.Conn.Write(value)
	}
	partial := len(value) / 2
	if partial == 0 {
		partial = 1
	}
	close(c.partialStarted)
	count, writeErr := c.Conn.Write(value[:partial])
	if writeErr != nil {
		return count, writeErr
	}
	close(c.partialWritten)
	<-c.release
	return count, c.err
}

func (c *partialNthWriteErrorConn) Write(value []byte) (int, error) {
	if c.writeCount.Add(1) != c.failOnWrite {
		return c.Conn.Write(value)
	}
	partial := len(value) / 2
	if partial == 0 {
		partial = 1
	}
	count, writeErr := c.Conn.Write(value[:partial])
	if writeErr != nil {
		return count, writeErr
	}
	return count, c.err
}

func (c *partialFrameWriteErrorConn) Write(value []byte) (int, error) {
	if !c.injected.CompareAndSwap(false, true) {
		return c.Conn.Write(value)
	}
	partial := len(value) / 2
	if partial == 0 {
		partial = 1
	}
	count, writeErr := c.Conn.Write(value[:partial])
	if writeErr != nil {
		return count, writeErr
	}
	return count, c.err
}

func (c *fullFrameWriteErrorConn) Write(value []byte) (int, error) {
	count, err := c.Conn.Write(value)
	if err == nil && count == len(value) && c.injected.CompareAndSwap(false, true) {
		return count, c.err
	}
	return count, err
}

func resourceClientForConn(t *testing.T, conn net.Conn) *Client {
	t.Helper()
	client, err := NewClient(context.Background(), ClientOptions{
		Timeout: 2 * time.Second,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return conn, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = client.Close(context.Background())
	})
	return client
}

func pingResult() map[string]any {
	return map[string]any{
		"alive": true,
		"cursor": map[string]any{
			"generation": "g",
			"revision":   "1",
		},
	}
}

func terminalWaitExitResult() map[string]any {
	return map[string]any{
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
			case "workspace.run", "pane.split":
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
			case "terminal.project":
				result = map[string]any{
					"generation": "g",
					"revision":   "17",
					"replayed":   false,
					"value": map[string]any{
						"id":           "tab_0000000000000000000000000000000a",
						"pane_id":      testPaneID,
						"name":         "mirror",
						"index":        2,
						"focused":      false,
						"content_kind": "terminal",
						"content_id":   testTerminalID,
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
		"protocol": "cmux.protocol/2",
		"type":     "response",
		"id":       id,
		"ok":       true,
		"result":   result,
	})
}

func writeSuccessOrClosed(t *testing.T, conn net.Conn, id any) {
	t.Helper()
	encoded, err := json.Marshal(map[string]any{
		"protocol": "cmux.protocol/2",
		"type":     "response",
		"id":       id,
		"ok":       true,
		"result":   map[string]any{},
	})
	if err != nil {
		t.Errorf("encode response: %v", err)
		return
	}
	encoded = append(encoded, '\n')
	if _, err := conn.Write(encoded); err != nil && !errors.Is(err, io.ErrClosedPipe) {
		t.Errorf("write response: %v", err)
	}
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
