package cmux

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestLegacyResizeResponseDefaultsToAccepted(t *testing.T) {
	var result ResizeSurfaceResult
	if err := json.Unmarshal([]byte(`{}`), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Accepted {
		t.Fatal("legacy resize response must be treated as accepted")
	}
}

func TestResizeResponsePreservesReservationIdentity(t *testing.T) {
	var result ResizeSurfaceResult
	if err := json.Unmarshal([]byte(`{"accepted":true,"reservation_id":41}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.ReservationID == nil || *result.ReservationID != 41 {
		t.Fatalf("reservation id = %v, want 41", result.ReservationID)
	}
}

func TestClientInfoNormalizesProtocolNineSizingParticipation(t *testing.T) {
	var result ClientInfo
	if err := json.Unmarshal([]byte(`{
		"client":7,
		"transport":"ws",
		"connected_seconds":12,
		"attached":[31,32],
		"sizes":[
			{"surface":31,"cols":126,"rows":38},
			{"surface":32,"cols":100,"rows":30,"size_participating":true}
		],
		"size_participating":false,
		"self":true
	}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.Sizes[0].SizeParticipating == nil || *result.Sizes[0].SizeParticipating {
		t.Fatalf("legacy participation = %v, want false", result.Sizes[0].SizeParticipating)
	}
	if result.Sizes[1].SizeParticipating == nil || !*result.Sizes[1].SizeParticipating {
		t.Fatalf("surface participation = %v, want true", result.Sizes[1].SizeParticipating)
	}
}

func TestCommandErrorPreservesMachineReadableCode(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout: time.Second,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		_ = encoder.Encode(map[string]any{
			"id":         request["id"],
			"ok":         false,
			"error":      "layout changed",
			"error_code": "layout-undo-stale",
		})
	}()

	err := client.request(context.Background(), "undo-layout", nil, nil)
	var commandError *CommandError
	if !errors.As(err, &commandError) {
		t.Fatalf("error = %v, want CommandError", err)
	}
	if commandError.ErrorCode != "layout-undo-stale" {
		t.Fatalf("error code = %q, want layout-undo-stale", commandError.ErrorCode)
	}
}

func TestWorkspaceRegistryTypesDecode(t *testing.T) {
	var tree Tree
	if err := json.Unmarshal([]byte(`{"workspace_revision":4,"pane_revision":7,"workspaces":[{"id":1,"key":"stable","name":"one","active":true,"screens":[]}]}`), &tree); err != nil {
		t.Fatal(err)
	}
	if tree.WorkspaceRevision != 4 || tree.PaneRevision == nil || *tree.PaneRevision != 7 || tree.Workspaces[0].Key != "stable" {
		t.Fatalf("tree = %#v", tree)
	}
	var legacyTree Tree
	if err := json.Unmarshal([]byte(`{"workspaces":[]}`), &legacyTree); err != nil {
		t.Fatal(err)
	}
	if legacyTree.PaneRevision != nil {
		t.Fatalf("legacy pane revision = %v, want nil", legacyTree.PaneRevision)
	}
	var viewportTree Tree
	if err := json.Unmarshal([]byte(`{"workspaces":[{"id":1,"name":"one","active":true,"screens":[{"id":2,"name":null,"active":true,"active_pane":3,"layout":{"type":"leaf","pane":3},"viewport_base_width":0.75,"viewport_splits":[{"split":4,"width":0.5}],"panes":[]}]}]}`), &viewportTree); err != nil {
		t.Fatal(err)
	}
	viewport := viewportTree.Workspaces[0].Screens[0]
	if viewport.ViewportBaseWidth == nil || *viewport.ViewportBaseWidth != 0.75 ||
		len(viewport.ViewportSplits) != 1 || viewport.ViewportSplits[0] != (ViewportSplit{Split: 4, Width: 0.5}) {
		t.Fatalf("viewport screen = %#v", viewport)
	}

	var placement WorkspacePlacement
	if err := json.Unmarshal([]byte(`{"workspace":1,"key":"stable","index":0,"workspace_revision":5}`), &placement); err != nil {
		t.Fatal(err)
	}
	if placement.WorkspaceRevision != 5 {
		t.Fatalf("placement = %#v", placement)
	}

	var mutation WorkspaceMutation
	if err := json.Unmarshal([]byte(`{"workspace":1,"key":"stable","workspace_revision":6}`), &mutation); err != nil {
		t.Fatal(err)
	}
	if mutation.WorkspaceRevision != 6 {
		t.Fatalf("mutation = %#v", mutation)
	}
}

func TestCreateTerminalPreservesExplicitlyEmptyArgv(t *testing.T) {
	if _, ok := commandMap(CreateTerminalOptions{})["argv"]; ok {
		t.Fatal("nil argv must remain absent for backward compatibility")
	}
	params := commandMap(CreateTerminalOptions{Argv: []string{}})
	argv, ok := params["argv"].([]any)
	if !ok || len(argv) != 0 {
		t.Fatalf("argv = %#v, want explicitly supplied empty array", params["argv"])
	}
}

func TestNewPaneRightRejectsInvalidWidthsWithoutSendingACommand(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(10)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"viewport-splits-v1": {}},
	}
	defer client.Close()

	requests := make(chan map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			requests <- request
			_ = encoder.Encode(map[string]any{
				"id":   request["id"],
				"ok":   true,
				"data": map[string]any{"surface": 9},
			})
		}
	}()

	for _, width := range []float32{
		float32(math.NaN()),
		float32(math.Inf(1)),
		float32(math.Inf(-1)),
		0.09,
		1.01,
	} {
		_, err := client.NewPaneRight(
			context.Background(),
			7,
			NewPaneRightOptions{Width: &width},
		)
		if !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("NewPaneRight(width=%v) error = %v, want invalid argument", width, err)
		}
	}

	select {
	case request := <-requests:
		t.Fatalf("invalid width sent request: %#v", request)
	default:
	}
}

func TestSetViewportPaneWidthRejectsInvalidWidthsWithoutSendingACommand(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(10)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"viewport-column-resize-v1": {}},
	}
	defer client.Close()

	requests := make(chan map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			requests <- request
			_ = encoder.Encode(map[string]any{
				"id":   request["id"],
				"ok":   true,
				"data": map[string]any{},
			})
		}
	}()

	for _, width := range []float32{
		float32(math.NaN()),
		float32(math.Inf(1)),
		float32(math.Inf(-1)),
		0.09,
		1.01,
	} {
		err := client.SetViewportPaneWidth(context.Background(), 7, width)
		if !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf(
				"SetViewportPaneWidth(width=%v) error = %v, want invalid argument",
				width,
				err,
			)
		}
	}

	select {
	case request := <-requests:
		t.Fatalf("invalid width sent request: %#v", request)
	default:
	}
}

func TestWorkspaceRegistrySelectorsRejectMissingAndEmptyKeysLocally(t *testing.T) {
	if err := validateWorkspaceSelector(nil, nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("missing selector error = %v", err)
	}
	empty := "  "
	if err := validateWorkspaceSelector(nil, &empty); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("empty key error = %v", err)
	}
	workspace := uint64(1)
	if err := validateWorkspaceSelector(&workspace, nil); err != nil {
		t.Fatalf("workspace selector error = %v", err)
	}
	key := "stable"
	if err := validateWorkspaceSelector(nil, &key); err != nil {
		t.Fatalf("key selector error = %v", err)
	}
}

func TestAttachSurfaceRejectsPartialInitialSizeLocally(t *testing.T) {
	cols := uint16(80)
	_, err := (&Client{}).AttachSurfaceWithOptions(
		context.Background(),
		1,
		AttachSurfaceOptions{Cols: &cols},
	)
	if !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("partial attach size error = %v", err)
	}
}

func TestIdentifyCapabilityStateIsConcurrentSafe(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout: time.Second,
		conn:    &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			if encoder.Encode(map[string]any{
				"id": request["id"],
				"ok": true,
				"data": map[string]any{
					"app": "cmux-tui", "version": "test", "protocol": 7,
					"capabilities": []string{"attach-initial-size"},
					"session":      "test", "pid": 1,
				},
			}) != nil {
				return
			}
		}
	}()

	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		for range 100 {
			if _, err := client.Identify(context.Background()); err != nil {
				t.Errorf("Identify() error = %v", err)
				return
			}
		}
	}()
	go func() {
		defer wait.Done()
		for range 10_000 {
			_ = client.hasCapability("attach-initial-size")
		}
	}()
	wait.Wait()
}

func TestIdentifyDetailsPreservesArtifactRevisions(t *testing.T) {
	var result IdentifyDetails
	if err := json.Unmarshal([]byte(`{"app":"cmux-tui","version":"0.1.2","build_commit":"cmux-sha","ghostty_commit":"ghostty-sha","protocol":7,"session":"main","pid":42}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.BuildCommit == nil || *result.BuildCommit != "cmux-sha" {
		t.Fatalf("build commit = %v, want cmux-sha", result.BuildCommit)
	}
	if result.GhosttyCommit == nil || *result.GhosttyCommit != "ghostty-sha" {
		t.Fatalf("ghostty commit = %v, want ghostty-sha", result.GhosttyCommit)
	}
}

func TestIdentifyDetailsAcceptsMissingArtifactRevisions(t *testing.T) {
	var result IdentifyDetails
	if err := json.Unmarshal([]byte(`{"app":"cmux-tui","version":"0.1.2","protocol":7,"session":"main","pid":42}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.BuildCommit != nil || result.GhosttyCommit != nil {
		t.Fatalf("artifact revisions = %v, %v; want nil", result.BuildCommit, result.GhosttyCommit)
	}
}

func TestIdentifyResultPreservesPositionalLiteralCompatibility(t *testing.T) {
	result := IdentifyResult{"cmux-tui", "0.1.2", 7, "main", 42}
	if result.Protocol != 7 || result.PID != 42 {
		t.Fatalf("legacy positional identify result = %#v", result)
	}
}

func TestSetSplitRatioRejectsServersOlderThanProtocolEight(t *testing.T) {
	protocol := uint32(7)
	client := &Client{protocol: &protocol}
	err := client.SetSplitRatio(context.Background(), 1, 0.5)
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("SetSplitRatio() error = %v, want protocol mismatch", err)
	}
}

func TestClearHistoryRequiresCapability(t *testing.T) {
	protocol := uint32(9)
	client := &Client{protocol: &protocol}
	err := client.ClearHistory(context.Background(), 7)
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("ClearHistory() error = %v, want protocol mismatch", err)
	}
}

func TestClearHistorySendsCapabilityGatedWireCommand(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(9)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"clear-history-v1": {}},
	}
	defer client.Close()

	requests := make(chan map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		requests <- request
		_ = encoder.Encode(map[string]any{"id": request["id"], "ok": true, "data": map[string]any{}})
	}()

	if err := client.ClearHistory(context.Background(), 7); err != nil {
		t.Fatalf("ClearHistory() error = %v", err)
	}
	request := <-requests
	if request["cmd"] != "clear-history" || request["surface"] != float64(7) {
		t.Fatalf("ClearHistory() request = %#v", request)
	}
}

func TestClearHistoryFallbackRequiresCapabilityAndPreservesKey(t *testing.T) {
	protocol := uint32(9)
	codepoint := "k"
	baseCodepoint := "k"
	action := TerminalKeyPress
	fallback := TerminalKeyInput{
		Key:                 TerminalKeyK,
		Mods:                TerminalModifiers{Super: true},
		UnshiftedCodepoint:  &codepoint,
		BaseLayoutCodepoint: &baseCodepoint,
		Action:              &action,
		MacOSOptionAsAlt:    true,
	}
	client := &Client{
		protocol:     &protocol,
		capabilities: map[string]struct{}{"clear-history-v1": {}},
	}
	err := client.ClearHistoryWithFallback(context.Background(), 7, fallback)
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("ClearHistoryWithFallback() error = %v, want protocol mismatch", err)
	}

	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client = &Client{
		timeout:  time.Second,
		conn:     &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol: &protocol,
		capabilities: map[string]struct{}{
			"clear-history-v1":     {},
			"clear-history-key-v1": {},
		},
	}
	defer client.Close()

	requests := make(chan map[string]any, 1)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		requests <- request
		_ = encoder.Encode(map[string]any{"id": request["id"], "ok": true, "data": map[string]any{}})
	}()

	if err := client.ClearHistoryWithFallback(context.Background(), 7, fallback); err != nil {
		t.Fatalf("ClearHistoryWithFallback() error = %v", err)
	}
	request := <-requests
	key, ok := request["fallback_key"].(map[string]any)
	if !ok {
		t.Fatalf("fallback_key = %#v", request["fallback_key"])
	}
	mods, ok := key["mods"].(map[string]any)
	if !ok ||
		key["key"] != "k" ||
		mods["super"] != true ||
		key["composing"] != false ||
		key["unshifted_codepoint"] != "k" ||
		key["shifted_codepoint"] != nil ||
		key["base_layout_codepoint"] != "k" ||
		key["action"] != "press" ||
		key["macos_option_as_alt"] != true {
		t.Fatalf("ClearHistoryWithFallback() fallback_key = %#v", key)
	}
}

func TestClearHistoryFailurePreservesDeliveryClassification(t *testing.T) {
	protocol := uint32(9)
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	client := &Client{
		timeout:  time.Second,
		conn:     &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol: &protocol,
		capabilities: map[string]struct{}{
			"clear-history-v1":     {},
			"clear-history-key-v1": {},
		},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		_ = encoder.Encode(map[string]any{
			"id":             request["id"],
			"ok":             false,
			"error":          "clear failed",
			"error_delivery": "known-not-delivered",
		})
	}()

	err := client.ClearHistoryWithFallback(
		context.Background(),
		7,
		TerminalKeyInput{Key: TerminalKeyK},
	)
	var commandError *CommandError
	if !errors.As(err, &commandError) {
		t.Fatalf("ClearHistoryWithFallback() error = %v, want CommandError", err)
	}
	if commandError.Delivery != ErrorDeliveryKnownNotDelivered {
		t.Fatalf("CommandError.Delivery = %q", commandError.Delivery)
	}
}

func TestClearHistoryFallbackRejectsOversizedKeyTextLocally(t *testing.T) {
	protocol := uint32(9)
	client := &Client{
		protocol: &protocol,
		capabilities: map[string]struct{}{
			"clear-history-v1":     {},
			"clear-history-key-v1": {},
		},
	}
	err := client.ClearHistoryWithFallback(context.Background(), 7, TerminalKeyInput{
		Key:  TerminalKeyK,
		UTF8: strings.Repeat("x", TerminalKeyTextMaxBytes+1),
	})
	if err == nil || !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("ClearHistoryWithFallback() error = %v, want invalid argument", err)
	}
	if !strings.Contains(err.Error(), "terminal key text exceeds the 4 KiB protocol limit") {
		t.Fatalf("ClearHistoryWithFallback() error = %v", err)
	}
}

func TestSetSplitRatioAcceptsNewerAdditiveProtocols(t *testing.T) {
	protocol := uint32(9)
	client := &Client{protocol: &protocol}
	if err := client.requireProtocol(context.Background(), 8, "set-split-ratio"); err != nil {
		t.Fatalf("requireProtocol() error = %v, want protocol 9 accepted", err)
	}
}

func TestResizeMethodsForwardExplicitTransactions(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(10)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"viewport-column-resize-v1": {}},
	}
	defer client.Close()

	requests := make(chan map[string]any, 2)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for range 2 {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			requests <- request
			_ = encoder.Encode(map[string]any{"id": request["id"], "ok": true, "data": map[string]any{}})
		}
	}()

	if err := client.SetSplitRatioInTransaction(context.Background(), 42, 0.6, 17); err != nil {
		t.Fatal(err)
	}
	if err := client.SetViewportPaneWidthInTransaction(context.Background(), 9, 0.75, 17); err != nil {
		t.Fatal(err)
	}

	split := <-requests
	if split["cmd"] != "set-split-ratio" || split["transaction"] != float64(17) {
		t.Fatalf("split request = %#v", split)
	}
	column := <-requests
	if column["cmd"] != "set-viewport-pane-width" || column["transaction"] != float64(17) {
		t.Fatalf("column request = %#v", column)
	}
}

func TestUndoLayoutPreservesPreviewRevisionForConfirmation(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(10)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"layout-undo-v1": {}},
	}
	defer client.Close()

	requests := make(chan map[string]any, 2)
	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		for range 2 {
			var request map[string]any
			if decoder.Decode(&request) != nil {
				return
			}
			requests <- request
			data := map[string]any{
				"undone": false, "confirmation_required": true,
				"screen": 3, "revision": 8, "closes_panes": []uint64{15},
			}
			if request["confirm_close"] == true {
				data = map[string]any{"undone": true, "screen": 3, "revision": 9}
			}
			_ = encoder.Encode(map[string]any{"id": request["id"], "ok": true, "data": data})
		}
	}()

	preview, err := client.UndoLayout(context.Background(), 15, nil)
	if err != nil {
		t.Fatal(err)
	}
	confirmation, ok := preview.(LayoutUndoConfirmationRequired)
	if !ok || confirmation.Revision != 8 || len(confirmation.ClosesPanes) != 1 {
		t.Fatalf("preview = %#v", preview)
	}
	result, err := client.UndoLayout(context.Background(), 15, &confirmation.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := result.(LayoutUndoUndone); !ok {
		t.Fatalf("result = %#v", result)
	}
	<-requests
	confirm := <-requests
	if confirm["revision"] != float64(8) || confirm["confirm_close"] != true {
		t.Fatalf("confirmation request = %#v", confirm)
	}
}

func TestUndoLayoutRejectsMissingClosesPanes(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	protocol := uint32(10)
	client := &Client{
		timeout:      time.Second,
		conn:         &jsonLineConn{conn: clientConn, reader: bufio.NewReader(clientConn)},
		protocol:     &protocol,
		capabilities: map[string]struct{}{"layout-undo-v1": {}},
	}
	defer client.Close()

	go func() {
		decoder := json.NewDecoder(serverConn)
		encoder := json.NewEncoder(serverConn)
		var request map[string]any
		if decoder.Decode(&request) != nil {
			return
		}
		_ = encoder.Encode(map[string]any{
			"id": request["id"],
			"ok": true,
			"data": map[string]any{
				"undone": false, "confirmation_required": true,
				"screen": 3, "revision": 8,
			},
		})
	}()

	_, err := client.UndoLayout(context.Background(), 15, nil)
	if err == nil || !errors.Is(err, ErrDecode) {
		t.Fatalf("UndoLayout() error = %v, want decode error", err)
	}
}

func TestNewPaneRejectsServersOlderThanProtocolNine(t *testing.T) {
	protocol := uint32(8)
	client := &Client{protocol: &protocol}
	_, err := client.NewPane(context.Background(), 1, NewPaneOptions{})
	if err == nil || !errors.Is(err, ErrProtocolMismatch) {
		t.Fatalf("NewPane() error = %v, want protocol mismatch", err)
	}
}

func TestStreamYieldsBufferedOverflowOnceThenStops(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	stream := &Stream{
		conn:     &jsonLineConn{conn: client, reader: bufio.NewReader(client)},
		buffered: []Event{OverflowEvent{Error: "fell behind"}},
	}

	event, err := stream.Recv(context.Background())
	if err != nil {
		t.Fatalf("first Recv() error = %v", err)
	}
	if _, ok := event.(OverflowEvent); !ok {
		t.Fatalf("first Recv() event = %#v", event)
	}
	if _, err := stream.Recv(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatalf("second Recv() error = %v, want io.EOF", err)
	}
}

func TestStreamCloseIsConcurrentSafe(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	stream := &Stream{conn: &jsonLineConn{conn: client, reader: bufio.NewReader(client)}}

	var wait sync.WaitGroup
	for range 16 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if err := stream.Close(); err != nil {
				t.Errorf("Close() error = %v", err)
			}
		}()
	}
	wait.Wait()

	if _, err := stream.Recv(context.Background()); !errors.Is(err, io.EOF) {
		t.Fatalf("Recv() error = %v, want io.EOF", err)
	}
}
