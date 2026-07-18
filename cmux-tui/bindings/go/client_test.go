package cmux

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestProtocolV8SharedVectorsDecodeTopologyAndRecovery(t *testing.T) {
	data, err := os.ReadFile("../conformance/topology-v8.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Identify          IdentifyResult               `json:"identify"`
		Ping              PingResult                   `json:"ping"`
		Snapshot          TopologySnapshot             `json:"snapshot"`
		Delta             TopologyDelta                `json:"delta"`
		ResnapshotResults []TopologyResnapshotRequired `json:"resnapshot_results"`
		SlowConsumer      TopologyResnapshotRequired   `json:"slow_consumer_event"`
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	cursor, ok := vectors.Identify.TopologyCursor()
	if !ok || cursor.Revision != 41 || vectors.Identify.TopologyRevision == nil || *vectors.Identify.TopologyRevision != 47 {
		t.Fatalf("identify cursor = %#v, ok=%v, identify=%#v", cursor, ok, vectors.Identify)
	}
	if !vectors.Ping.OK || vectors.Ping.CanonicalTopologyRevision == nil || *vectors.Ping.CanonicalTopologyRevision != 41 ||
		vectors.Ping.TopologyRevision == nil || *vectors.Ping.TopologyRevision != 47 {
		t.Fatalf("ping = %#v", vectors.Ping)
	}
	if vectors.Snapshot.Revision != 41 || vectors.Snapshot.Topology.Workspaces[0].Screens[0].Panes[0].Tabs[0].ID != 4 {
		t.Fatalf("snapshot = %#v", vectors.Snapshot)
	}
	if vectors.Delta.Operation != TopologyWorkspaceRenamed {
		t.Fatalf("operation = %q", vectors.Delta.Operation)
	}
	if required := validateTopologyDelta(vectors.Snapshot.Cursor(), vectors.Delta); required != nil {
		t.Fatalf("adjacent delta required resnapshot: %#v", required)
	}
	want := []TopologyResnapshotReason{
		TopologyStaleDaemon,
		TopologyStaleSession,
		TopologyRevisionAhead,
		TopologyHistoryGap,
		TopologyReplayTooLarge,
	}
	for index, reason := range want {
		if vectors.ResnapshotResults[index].Reason != reason {
			t.Fatalf("reason[%d] = %q, want %q", index, vectors.ResnapshotResults[index].Reason, reason)
		}
	}
	if vectors.SlowConsumer.Reason != TopologySlowConsumer || vectors.SlowConsumer.CurrentRevision != nil {
		t.Fatalf("slow consumer = %#v", vectors.SlowConsumer)
	}
}

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

func TestProcessInfoDecodesArgvAndCanonicalTTY(t *testing.T) {
	var result ProcessInfoResult
	if err := json.Unmarshal([]byte(`{"pid":42,"command":["/bin/zsh","-l"],"cwd":"/tmp","tty":"/dev/ttys004"}`), &result); err != nil {
		t.Fatal(err)
	}
	if result.PID == nil || *result.PID != 42 || result.CWD == nil || *result.CWD != "/tmp" || result.TTY == nil || *result.TTY != "/dev/ttys004" {
		t.Fatalf("process info = %#v", result)
	}
	if len(result.Command) != 2 || result.Command[0] != "/bin/zsh" || result.Command[1] != "-l" {
		t.Fatalf("command = %#v", result.Command)
	}
	if err := json.Unmarshal([]byte(`{"pid":42,"command":"/bin/zsh -l","cwd":null,"tty":null}`), &result); err == nil {
		t.Fatal("legacy joined command must not decode as argv")
	}
}

func TestEnsureTerminalWireIncludesWaitPolicyAndDecodesStablePlacement(t *testing.T) {
	opts := EnsureTerminalOptions{
		Argv:             []string{"/bin/zsh", "-l"},
		Environment:      []EnsureTerminalEnvironment{{Name: "CMUX_TEST", Value: "1"}},
		WaitAfterCommand: true,
	}
	params := commandMap(opts)
	if params["wait_after_command"] != true {
		t.Fatalf("wait_after_command = %#v, want true", params["wait_after_command"])
	}
	if _, ok := params["env"].([]any); !ok {
		t.Fatalf("env = %#v, want JSON array", params["env"])
	}

	var result EnsureTerminalResult
	if err := json.Unmarshal([]byte(`{"created":true,"workspace":1,"workspace_uuid":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","screen":2,"screen_uuid":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","pane":3,"pane_uuid":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","surface":4,"surface_uuid":"ffffffff-ffff-4fff-8fff-ffffffffffff"}`), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Created || result.Surface != 4 || result.SurfaceUUID != UUID("ffffffff-ffff-4fff-8fff-ffffffffffff") {
		t.Fatalf("ensure terminal result = %#v", result)
	}
}

func TestReparentTerminalDecodesStablePlacement(t *testing.T) {
	var result ReparentTerminalResult
	if err := json.Unmarshal([]byte(`{"moved":true,"workspace":1,"workspace_uuid":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","screen":2,"screen_uuid":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","pane":3,"pane_uuid":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","surface":4,"surface_uuid":"ffffffff-ffff-4fff-8fff-ffffffffffff"}`), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Moved || result.Surface != 4 || result.SurfaceUUID != UUID("ffffffff-ffff-4fff-8fff-ffffffffffff") {
		t.Fatalf("reparent terminal result = %#v", result)
	}
}

func TestDefaultSocketRuntimeRootPrefersXDGAndIgnoresEmptyValues(t *testing.T) {
	if got := runtimeBase("/xdg-runtime", "/tmp-runtime"); got != "/xdg-runtime" {
		t.Fatalf("runtimeBase() = %q, want /xdg-runtime", got)
	}
	if got := runtimeBase("", "/tmp-runtime"); got != "/tmp-runtime" {
		t.Fatalf("runtimeBase() = %q, want /tmp-runtime", got)
	}
	if got := runtimeBase("", ""); got != "/tmp" {
		t.Fatalf("runtimeBase() = %q, want /tmp", got)
	}
}

func TestDarwinDefaultSocketPathAccepts103BytesAndFallsBackAt104(t *testing.T) {
	base := "/tmp/runtime"
	uid := 42
	emptySession := filepath.Join(base, "cmux-tui-42", ".sock")
	session := strings.Repeat("s", 103-len(emptySession))

	accepted := defaultSocketPathFrom(base, uid, session, true)
	if len(accepted) != 103 {
		t.Fatalf("accepted path length = %d, want 103", len(accepted))
	}
	if filepath.Dir(filepath.Dir(accepted)) != base {
		t.Fatalf("accepted path = %q, want runtime base %q", accepted, base)
	}

	fallback := defaultSocketPathFrom(base, uid, session+"s", true)
	wantPrefix := filepath.Join("/tmp", "cmux-tui-42") + string(filepath.Separator)
	if len(fallback) < len(wantPrefix) || fallback[:len(wantPrefix)] != wantPrefix {
		t.Fatalf("fallback path = %q, want prefix %q", fallback, wantPrefix)
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
