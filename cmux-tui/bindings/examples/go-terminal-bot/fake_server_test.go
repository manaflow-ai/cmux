package terminalbot_test

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

const (
	fakeWorkspaceID    cmux.ID = math.MaxUint64 - 40
	fakeScreenID       cmux.ID = math.MaxUint64 - 39
	fakePaneID         cmux.ID = math.MaxUint64 - 38
	fakeSurfaceID      cmux.ID = math.MaxUint64 - 37
	fakeNotificationID cmux.ID = math.MaxUint64 - 36

	fakeWorkspaceRevision uint64 = math.MaxUint64 - 1_000
	fakeTerminalRevision  uint64 = math.MaxUint64 - 900
)

type fakeScenario struct {
	existingWorkspace bool
	complete          bool
	reconnectStreams  bool
	exitCode          int
}

type requestRecord struct {
	command            string
	expectedGeneration string
	expectedRevision   string
	workspace          string
	surface            string
	state              string
	level              string
	text               string
}

type fakeServer struct {
	listener   net.Listener
	socketPath string
	acceptDone chan struct{}
	handlers   sync.WaitGroup

	scenario fakeScenario

	mu                   sync.Mutex
	connections          map[*fakeConnection]struct{}
	subscriptions        []*fakeConnection
	attachments          []*fakeConnection
	records              []requestRecord
	unexpected           []string
	workspaceKey         string
	terminalID           string
	marker               string
	remainingOutput      string
	workspaceExists      bool
	surfaceExists        bool
	taskStarted          bool
	taskExited           bool
	workspaceRevision    uint64
	terminalRevision     uint64
	subscribeCount       int
	attachCount          int
	firstSubscribeClosed bool
	firstAttachClosed    bool
	started              chan struct{}
	startedOnce          sync.Once
}

type fakeConnection struct {
	server *fakeServer
	conn   net.Conn
	mu     sync.Mutex
}

func startFakeServer(t *testing.T, scenario fakeScenario) *fakeServer {
	t.Helper()
	tempDir, err := os.MkdirTemp("/tmp", "cmux-go-bot-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tempDir) })
	socketPath := filepath.Join(tempDir, "server.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	server := &fakeServer{
		listener:          listener,
		socketPath:        socketPath,
		acceptDone:        make(chan struct{}),
		scenario:          scenario,
		connections:       make(map[*fakeConnection]struct{}),
		workspaceExists:   scenario.existingWorkspace,
		workspaceRevision: fakeWorkspaceRevision,
		terminalRevision:  fakeTerminalRevision,
		started:           make(chan struct{}),
	}
	go server.accept()
	t.Cleanup(server.Close)
	return server
}

func (server *fakeServer) accept() {
	defer close(server.acceptDone)
	for {
		conn, err := server.listener.Accept()
		if err != nil {
			return
		}
		connection := &fakeConnection{server: server, conn: conn}
		server.mu.Lock()
		server.connections[connection] = struct{}{}
		server.mu.Unlock()
		server.handlers.Add(1)
		go connection.serve()
	}
}

func (server *fakeServer) Close() {
	_ = server.listener.Close()
	<-server.acceptDone
	server.mu.Lock()
	connections := make([]*fakeConnection, 0, len(server.connections))
	for connection := range server.connections {
		connections = append(connections, connection)
	}
	server.mu.Unlock()
	for _, connection := range connections {
		_ = connection.conn.Close()
	}
	server.handlers.Wait()
}

func (connection *fakeConnection) serve() {
	defer connection.server.handlers.Done()
	defer connection.remove()
	defer connection.conn.Close()

	decoder := json.NewDecoder(bufio.NewReader(connection.conn))
	decoder.UseNumber()
	for {
		var request map[string]any
		if err := decoder.Decode(&request); err != nil {
			return
		}
		connection.server.handle(connection, request)
	}
}

func (connection *fakeConnection) remove() {
	server := connection.server
	server.mu.Lock()
	delete(server.connections, connection)
	server.subscriptions = removeConnection(server.subscriptions, connection)
	server.attachments = removeConnection(server.attachments, connection)
	server.mu.Unlock()
}

func removeConnection(
	connections []*fakeConnection,
	target *fakeConnection,
) []*fakeConnection {
	filtered := connections[:0]
	for _, connection := range connections {
		if connection != target {
			filtered = append(filtered, connection)
		}
	}
	return filtered
}

func (connection *fakeConnection) send(value any) error {
	connection.mu.Lock()
	defer connection.mu.Unlock()
	return json.NewEncoder(connection.conn).Encode(value)
}

func (connection *fakeConnection) respond(request map[string]any, data any) {
	_ = connection.send(map[string]any{
		"id":   request["id"],
		"ok":   true,
		"data": data,
	})
}

func (server *fakeServer) handle(
	connection *fakeConnection,
	request map[string]any,
) {
	command, _ := request["cmd"].(string)
	server.record(command, request)
	switch command {
	case "identify":
		connection.respond(request, server.identify())
	case "subscribe":
		server.handleSubscribe(connection, request)
	case "list-workspaces":
		connection.respond(request, server.tree())
	case "create-workspace":
		server.handleCreateWorkspace(connection, request)
	case "list-terminals":
		connection.respond(request, server.terminals())
	case "create-terminal":
		server.handleCreateTerminal(connection, request)
	case "attach-surface":
		server.handleAttach(connection, request)
	case "report-agent":
		connection.respond(request, map[string]any{
			"surface": request["surface"],
			"source":  request["source"],
			"state":   request["state"],
			"session": request["session"],
		})
	case "send":
		server.handleSend(connection, request)
	case "read-screen":
		connection.respond(request, map[string]any{"text": server.screenText()})
	case "read-scrollback":
		server.handleReadScrollback(connection, request)
	case "notify":
		connection.respond(request, map[string]any{
			"notification": uint64(fakeNotificationID),
		})
	case "close-workspace":
		server.handleCloseWorkspace(connection, request)
	default:
		server.mu.Lock()
		server.unexpected = append(server.unexpected, command)
		server.mu.Unlock()
		_ = connection.send(map[string]any{
			"id":    request["id"],
			"ok":    false,
			"error": "unsupported fake command " + command,
		})
	}
}

func (server *fakeServer) identify() map[string]any {
	server.mu.Lock()
	defer server.mu.Unlock()
	return map[string]any{
		"app":                "cmux-tui",
		"capabilities":       []string{"workspace-registry-v1"},
		"daemon_handoff":     int64(1),
		"generation":         "generation-exact",
		"pid":                uint32(4242),
		"protocol":           uint32(cmux.MuxProtocolVersion),
		"registry_id":        "registry-exact",
		"session":            "test",
		"terminal_revision":  server.terminalRevision,
		"version":            "test",
		"workspace_revision": server.workspaceRevision,
	}
}

func (server *fakeServer) tree() map[string]any {
	server.mu.Lock()
	defer server.mu.Unlock()
	workspaces := []any{}
	if server.workspaceExists {
		workspaces = append(workspaces, map[string]any{
			"active":  true,
			"id":      uint64(fakeWorkspaceID),
			"key":     server.workspaceKey,
			"name":    "Go terminal bot",
			"screens": []any{},
		})
	}
	return map[string]any{
		"generation":         "generation-exact",
		"pane_revision":      uint64(math.MaxUint64 - 800),
		"registry_id":        "registry-exact",
		"terminal_revision":  server.terminalRevision,
		"workspace_revision": server.workspaceRevision,
		"workspaces":         workspaces,
	}
}

func (server *fakeServer) handleCreateWorkspace(
	connection *fakeConnection,
	request map[string]any,
) {
	key, _ := request["key"].(string)
	server.mu.Lock()
	server.workspaceKey = key
	server.workspaceExists = true
	server.workspaceRevision++
	revision := server.workspaceRevision
	server.mu.Unlock()
	connection.respond(request, map[string]any{
		"changed":            true,
		"generation":         "generation-exact",
		"index":              uint64(math.MaxUint64 - 700),
		"key":                key,
		"registry_id":        "registry-exact",
		"replayed":           false,
		"workspace":          uint64(fakeWorkspaceID),
		"workspace_revision": revision,
	})
}

func (server *fakeServer) terminals() map[string]any {
	server.mu.Lock()
	defer server.mu.Unlock()
	return map[string]any{
		"generation":        "generation-exact",
		"registry_id":       "registry-exact",
		"terminal_revision": server.terminalRevision,
		"terminals":         []any{},
	}
}

func (server *fakeServer) handleCreateTerminal(
	connection *fakeConnection,
	request map[string]any,
) {
	terminalID, _ := request["terminal_id"].(string)
	server.mu.Lock()
	server.terminalID = terminalID
	server.surfaceExists = true
	server.terminalRevision++
	revision := server.terminalRevision
	key := server.workspaceKey
	server.mu.Unlock()
	connection.respond(request, map[string]any{
		"generation":           "generation-exact",
		"key":                  key,
		"lifecycle":            nil,
		"pane":                 uint64(fakePaneID),
		"registry_id":          "registry-exact",
		"replayed":             false,
		"screen":               uint64(fakeScreenID),
		"surface":              uint64(fakeSurfaceID),
		"terminal_id":          terminalID,
		"terminal_incarnation": "incarnation-exact",
		"terminal_revision":    revision,
		"workspace":            uint64(fakeWorkspaceID),
	})
}

func (server *fakeServer) handleSubscribe(
	connection *fakeConnection,
	request map[string]any,
) {
	server.mu.Lock()
	server.subscribeCount++
	server.subscriptions = append(server.subscriptions, connection)
	server.mu.Unlock()
	connection.respond(request, map[string]any{})
}

func (server *fakeServer) handleAttach(
	connection *fakeConnection,
	request map[string]any,
) {
	server.mu.Lock()
	server.attachCount++
	attachCount := server.attachCount
	taskStarted := server.taskStarted
	remaining := server.remainingOutput
	if attachCount > 1 {
		server.remainingOutput = ""
	}
	server.attachments = append(server.attachments, connection)
	server.mu.Unlock()

	if attachCount == 1 {
		_ = connection.send(map[string]any{
			"event":   "vt-state",
			"surface": uint64(fakeSurfaceID),
			"cols":    uint16(80),
			"rows":    uint16(24),
			"data":    base64.StdEncoding.EncodeToString([]byte("$ ")),
		})
	} else if taskStarted && remaining != "" {
		_ = connection.send(map[string]any{
			"event":   "output",
			"surface": uint64(fakeSurfaceID),
			"data":    base64.StdEncoding.EncodeToString([]byte(remaining)),
		})
	}
	connection.respond(request, map[string]any{})
}

func (server *fakeServer) handleSend(
	connection *fakeConnection,
	request map[string]any,
) {
	text, _ := request["text"].(string)
	connection.respond(request, map[string]any{})
	if text == "\n" {
		server.mu.Lock()
		server.taskExited = true
		server.surfaceExists = false
		subscriptions := append([]*fakeConnection(nil), server.subscriptions...)
		attachments := append([]*fakeConnection(nil), server.attachments...)
		server.mu.Unlock()
		for _, subscription := range subscriptions {
			_ = subscription.send(map[string]any{
				"event":   "surface-exited",
				"surface": uint64(fakeSurfaceID),
			})
		}
		for _, attachment := range attachments {
			_ = attachment.send(map[string]any{
				"event":   "detached",
				"surface": uint64(fakeSurfaceID),
			})
		}
		return
	}

	marker := regexp.MustCompile(`CMUX_TERMINAL_BOT_DONE_[[:xdigit:]]+`).
		FindString(text)
	server.mu.Lock()
	server.marker = marker
	server.taskStarted = true
	complete := server.scenario.complete
	reconnect := server.scenario.reconnectStreams
	exitCode := server.scenario.exitCode
	subscriptions := append([]*fakeConnection(nil), server.subscriptions...)
	attachments := append([]*fakeConnection(nil), server.attachments...)
	server.mu.Unlock()
	server.startedOnce.Do(func() { close(server.started) })

	if !complete {
		server.broadcastOutput(attachments, "task started\n", false)
		return
	}
	output := "compile started\n" + marker + ":" + strconv.Itoa(exitCode) + "\n"
	if !reconnect {
		server.broadcastOutput(attachments, output, false)
		return
	}

	split := strings.Index(output, marker) + len(marker)/2
	server.mu.Lock()
	server.remainingOutput = output[split:]
	server.mu.Unlock()
	server.broadcastOutput(attachments, output[:split], true)
	for _, subscription := range subscriptions {
		_ = subscription.send(map[string]any{
			"event":   "surface-output",
			"surface": uint64(fakeSurfaceID),
		})
		server.mu.Lock()
		shouldClose := !server.firstSubscribeClosed
		if shouldClose {
			server.firstSubscribeClosed = true
		}
		server.mu.Unlock()
		if shouldClose {
			_ = subscription.conn.Close()
			break
		}
	}
}

func (server *fakeServer) broadcastOutput(
	attachments []*fakeConnection,
	output string,
	closeFirst bool,
) {
	for _, attachment := range attachments {
		_ = attachment.send(map[string]any{
			"event":   "output",
			"surface": uint64(fakeSurfaceID),
			"data":    base64.StdEncoding.EncodeToString([]byte(output)),
		})
		if closeFirst {
			server.mu.Lock()
			shouldClose := !server.firstAttachClosed
			if shouldClose {
				server.firstAttachClosed = true
			}
			server.mu.Unlock()
			if shouldClose {
				_ = attachment.conn.Close()
				break
			}
		}
	}
}

func (server *fakeServer) screenText() string {
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.marker == "" || !server.scenario.complete {
		return "task running"
	}
	return "compile started\n" + server.marker + ":" +
		strconv.Itoa(server.scenario.exitCode)
}

func (server *fakeServer) handleReadScrollback(
	connection *fakeConnection,
	request map[string]any,
) {
	count, _ := request["count"].(json.Number)
	if count.String() == "0" {
		connection.respond(request, map[string]any{
			"rows":  []any{},
			"start": uint32(0),
			"total": uint32(3),
		})
		return
	}
	connection.respond(request, map[string]any{
		"rows": []any{
			renderRow(0, "task started"),
			renderRow(1, "compile started"),
			renderRow(2, server.screenText()),
		},
		"start": uint32(0),
		"total": uint32(3),
	})
}

func renderRow(row uint32, text string) map[string]any {
	return map[string]any{
		"row": row,
		"runs": []any{map[string]any{
			"attrs": uint32(0),
			"bg":    nil,
			"fg":    nil,
			"text":  text,
		}},
	}
}

func (server *fakeServer) handleCloseWorkspace(
	connection *fakeConnection,
	request map[string]any,
) {
	server.mu.Lock()
	server.workspaceExists = false
	server.workspaceRevision++
	revision := server.workspaceRevision
	key := server.workspaceKey
	server.mu.Unlock()
	connection.respond(request, map[string]any{
		"changed":            true,
		"generation":         "generation-exact",
		"index":              uint64(math.MaxUint64 - 700),
		"key":                key,
		"registry_id":        "registry-exact",
		"replayed":           false,
		"workspace":          uint64(fakeWorkspaceID),
		"workspace_revision": revision,
	})
}

func (server *fakeServer) record(command string, request map[string]any) {
	record := requestRecord{
		command:            command,
		expectedGeneration: stringField(request["expected_generation"]),
		expectedRevision:   numberField(request["expected_revision"]),
		workspace:          numberField(request["workspace"]),
		surface:            numberField(request["surface"]),
		state:              stringField(request["state"]),
		level:              stringField(request["level"]),
		text:               stringField(request["text"]),
	}
	server.mu.Lock()
	server.records = append(server.records, record)
	server.mu.Unlock()
}

func stringField(value any) string {
	text, _ := value.(string)
	return text
}

func numberField(value any) string {
	switch number := value.(type) {
	case json.Number:
		return number.String()
	case nil:
		return ""
	default:
		return fmt.Sprint(number)
	}
}

func (server *fakeServer) recordsFor(command string) []requestRecord {
	server.mu.Lock()
	defer server.mu.Unlock()
	var records []requestRecord
	for _, record := range server.records {
		if record.command == command {
			records = append(records, record)
		}
	}
	return records
}

func (server *fakeServer) assertHealthy(t *testing.T) {
	t.Helper()
	server.mu.Lock()
	defer server.mu.Unlock()
	if len(server.unexpected) > 0 {
		t.Fatalf("unexpected fake commands: %v", server.unexpected)
	}
}

func requireRecord(t *testing.T, records []requestRecord) requestRecord {
	t.Helper()
	if len(records) != 1 {
		t.Fatalf("got %d records, want 1: %#v", len(records), records)
	}
	return records[0]
}

func requireErrorIs(t *testing.T, err error, target error) {
	t.Helper()
	if !errors.Is(err, target) {
		t.Fatalf("got error %v, want errors.Is(..., %v)", err, target)
	}
}
