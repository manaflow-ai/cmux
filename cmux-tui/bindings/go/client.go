package cmux

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	ErrCommand          = errors.New("cmux-tui command error")
	ErrConnection       = errors.New("cmux-tui connection error")
	ErrTimeout          = errors.New("cmux-tui timeout")
	ErrProtocolMismatch = errors.New("cmux-tui protocol mismatch")
	ErrDecode           = errors.New("cmux-tui decode error")
	ErrInvalidArgument  = errors.New("cmux-tui invalid argument")
)

func validateWorkspaceSelector(workspace *uint64, key *string) error {
	if workspace == nil && (key == nil || strings.TrimSpace(*key) == "") {
		return fmt.Errorf("%w: workspace or key is required", ErrInvalidArgument)
	}
	if key != nil && strings.TrimSpace(*key) == "" {
		return fmt.Errorf("%w: workspace key cannot be empty", ErrInvalidArgument)
	}
	return nil
}

type CommandError struct {
	Message string
	ID      any
}

func (e *CommandError) Error() string { return e.Message }
func (e *CommandError) Is(target error) bool {
	return target == ErrCommand
}

type connectionError struct{ msg string }

func (e *connectionError) Error() string { return e.msg }
func (e *connectionError) Is(target error) bool {
	return target == ErrConnection
}

type timeoutError struct{ msg string }

func (e *timeoutError) Error() string { return e.msg }
func (e *timeoutError) Is(target error) bool {
	return target == ErrTimeout
}

type protocolError struct{ msg string }

func (e *protocolError) Error() string { return e.msg }
func (e *protocolError) Is(target error) bool {
	return target == ErrProtocolMismatch
}

type decodeError struct{ msg string }

func (e *decodeError) Error() string { return e.msg }
func (e *decodeError) Is(target error) bool {
	return target == ErrDecode
}

type Client struct {
	socketPath            string
	timeout               time.Duration
	allowProtocolV6Attach bool
	conn                  *jsonLineConn
	mu                    sync.Mutex
	nextID                atomic.Uint64
	negotiationMu         sync.RWMutex
	protocol              *uint32
	capabilities          map[string]struct{}
}

type Options struct {
	SocketPath            string
	Session               string
	Timeout               time.Duration
	AllowProtocolV6Attach bool
}

func NewClient(options Options) (*Client, error) {
	session := options.Session
	if session == "" {
		session = "main"
	}
	socketPath := options.SocketPath
	if socketPath == "" {
		socketPath = EnvSocketPath()
	}
	if socketPath == "" {
		socketPath = DefaultSocketPath(session)
	}
	timeout := options.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	conn, err := dialJSON(socketPath)
	if err != nil {
		return nil, err
	}
	return &Client{
		socketPath:            socketPath,
		timeout:               timeout,
		allowProtocolV6Attach: options.AllowProtocolV6Attach,
		conn:                  conn,
	}, nil
}

func DefaultSocketPath(session string) string {
	base := os.Getenv("TMPDIR")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, fmt.Sprintf("cmux-tui-%d", os.Getuid()), session+".sock")
}

func EnvSocketPath() string {
	if socketPath := os.Getenv("CMUX_TUI_SOCKET"); socketPath != "" {
		return socketPath
	}
	return os.Getenv("CMUX_MUX_SOCKET")
}

func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

func (c *Client) SendRaw(ctx context.Context, req map[string]any) (map[string]any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	request := make(map[string]any, len(req)+1)
	for k, v := range req {
		request[k] = v
	}
	if _, ok := request["id"]; !ok {
		request["id"] = c.nextRequestID()
	}
	requestID := request["id"]
	if err := c.conn.Send(ctx, c.timeout, request); err != nil {
		return nil, err
	}
	for {
		response, err := c.conn.Recv(ctx, c.timeout)
		if err != nil {
			return nil, err
		}
		if _, ok := response["event"].(string); ok {
			continue
		}
		if id, ok := response["id"]; ok && !sameJSONValue(id, requestID) {
			continue
		}
		return response, nil
	}
}

func (c *Client) request(ctx context.Context, cmd string, params map[string]any, out any) error {
	if params == nil {
		params = map[string]any{}
	}
	params["id"] = c.nextRequestID()
	params["cmd"] = cmd
	response, err := c.SendRaw(ctx, params)
	if err != nil {
		return err
	}
	if ok, _ := response["ok"].(bool); ok {
		data, _ := response["data"]
		encoded, err := json.Marshal(data)
		if err != nil {
			return &decodeError{msg: err.Error()}
		}
		if out == nil {
			return nil
		}
		if err := json.Unmarshal(encoded, out); err != nil {
			return &decodeError{msg: err.Error()}
		}
		return nil
	}
	msg, _ := response["error"].(string)
	if msg == "" {
		msg = "unknown error"
	}
	return &CommandError{Message: msg, ID: response["id"]}
}

func (c *Client) nextRequestID() uint64 {
	return c.nextID.Add(1)
}

func (c *Client) Identify(ctx context.Context) (IdentifyResult, error) {
	var details IdentifyDetails
	err := c.request(ctx, "identify", nil, &details)
	if err == nil {
		capabilities := make(map[string]struct{}, len(details.Capabilities))
		for _, capability := range details.Capabilities {
			capabilities[capability] = struct{}{}
		}
		protocol := details.Protocol
		c.negotiationMu.Lock()
		c.protocol = &protocol
		c.capabilities = capabilities
		c.negotiationMu.Unlock()
	}
	return IdentifyResult{
		App:      details.App,
		Version:  details.Version,
		Protocol: details.Protocol,
		Session:  details.Session,
		PID:      details.PID,
	}, err
}

// IdentifyDetailed identifies the server with optional immutable build revisions.
func (c *Client) IdentifyDetailed(ctx context.Context) (IdentifyDetails, error) {
	var result IdentifyDetails
	err := c.request(ctx, "identify", nil, &result)
	if err == nil {
		capabilities := make(map[string]struct{}, len(result.Capabilities))
		for _, capability := range result.Capabilities {
			capabilities[capability] = struct{}{}
		}
		protocol := result.Protocol
		c.negotiationMu.Lock()
		c.protocol = &protocol
		c.capabilities = capabilities
		c.negotiationMu.Unlock()
	}
	return result, err
}

func (c *Client) requireProtocol(ctx context.Context, minimum uint32, feature string) error {
	protocol, identified, _ := c.negotiatedState("")
	if !identified {
		if _, err := c.Identify(ctx); err != nil {
			return err
		}
		protocol, _, _ = c.negotiatedState("")
	}
	if protocol < minimum {
		return &protocolError{msg: fmt.Sprintf(
			"%s requires protocol %d; server uses protocol %d",
			feature, minimum, protocol,
		)}
	}
	return nil
}

func (c *Client) ListWorkspaces(ctx context.Context) (Tree, error) {
	var result Tree
	return result, c.request(ctx, "list-workspaces", nil, &result)
}

func (c *Client) Send(ctx context.Context, surface uint64, opts SendOptions) error {
	params := map[string]any{"surface": surface}
	if opts.Text != nil {
		params["text"] = *opts.Text
	}
	if opts.Bytes != nil {
		params["bytes"] = base64.StdEncoding.EncodeToString(opts.Bytes)
	}
	if opts.Base64Bytes != "" {
		params["bytes"] = opts.Base64Bytes
	}
	return c.request(ctx, "send", params, nil)
}

func (c *Client) ReadScreen(ctx context.Context, surface uint64) (ReadScreenResult, error) {
	var result ReadScreenResult
	return result, c.request(ctx, "read-screen", map[string]any{"surface": surface}, &result)
}

func (c *Client) VtState(ctx context.Context, surface uint64) (VtStateResult, error) {
	var result VtStateResult
	return result, c.request(ctx, "vt-state", map[string]any{"surface": surface}, &result)
}

func (c *Client) NewTab(ctx context.Context, opts NewTabOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-tab", commandMap(opts), &result)
}

func (c *Client) NewBrowserTab(ctx context.Context, url string, opts NewBrowserTabOptions) (SurfaceResult, error) {
	params := commandMap(opts)
	params["url"] = url
	var result SurfaceResult
	return result, c.request(ctx, "new-browser-tab", params, &result)
}

func (c *Client) NewWorkspace(ctx context.Context, opts NewWorkspaceOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-workspace", commandMap(opts), &result)
}

func (c *Client) CreateWorkspace(ctx context.Context, opts CreateWorkspaceOptions) (WorkspacePlacement, error) {
	var result WorkspacePlacement
	if err := c.requireCapability(ctx, "workspace-registry-v1", "workspace registry"); err != nil {
		return result, err
	}
	return result, c.request(ctx, "create-workspace", commandMap(opts), &result)
}

func (c *Client) CreateTerminal(ctx context.Context, opts CreateTerminalOptions) (TerminalPlacement, error) {
	var result TerminalPlacement
	if err := validateWorkspaceSelector(opts.Workspace, opts.Key); err != nil {
		return result, err
	}
	if err := c.requireCapability(ctx, "workspace-registry-v1", "workspace registry"); err != nil {
		return result, err
	}
	return result, c.request(ctx, "create-terminal", commandMap(opts), &result)
}

func (c *Client) NewScreen(ctx context.Context, opts NewScreenOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-screen", commandMap(opts), &result)
}

func (c *Client) NewPane(ctx context.Context, pane uint64, opts NewPaneOptions) (SurfaceResult, error) {
	if err := c.requireProtocol(ctx, 9, "new-pane"); err != nil {
		return SurfaceResult{}, err
	}
	params := commandMap(opts)
	params["pane"] = pane
	var result SurfaceResult
	return result, c.request(ctx, "new-pane", params, &result)
}

func (c *Client) Split(ctx context.Context, pane uint64, dir string, opts SplitOptions) (SurfaceResult, error) {
	params := commandMap(opts)
	params["pane"] = pane
	params["dir"] = dir
	var result SurfaceResult
	return result, c.request(ctx, "split", params, &result)
}

func (c *Client) SetRatio(ctx context.Context, pane uint64, dir string, ratio float32) error {
	return c.request(ctx, "set-ratio", map[string]any{"pane": pane, "dir": dir, "ratio": ratio}, nil)
}

func (c *Client) SetSplitRatio(ctx context.Context, split uint64, ratio float32) error {
	if err := c.requireProtocol(ctx, 8, "set-split-ratio"); err != nil {
		return err
	}
	return c.request(ctx, "set-split-ratio", map[string]any{"split": split, "ratio": ratio}, nil)
}

func (c *Client) SetDefaultColors(ctx context.Context, fg, bg *string) error {
	params := map[string]any{}
	if fg != nil {
		params["fg"] = *fg
	}
	if bg != nil {
		params["bg"] = *bg
	}
	return c.request(ctx, "set-default-colors", params, nil)
}

func (c *Client) CloseSurface(ctx context.Context, surface uint64) error {
	return c.request(ctx, "close-surface", map[string]any{"surface": surface}, nil)
}

func (c *Client) ClosePane(ctx context.Context, pane uint64) error {
	return c.request(ctx, "close-pane", map[string]any{"pane": pane}, nil)
}

func (c *Client) CloseScreen(ctx context.Context, screen uint64) error {
	return c.request(ctx, "close-screen", map[string]any{"screen": screen}, nil)
}

func (c *Client) CloseWorkspace(ctx context.Context, workspace uint64) error {
	return c.request(ctx, "close-workspace", map[string]any{"workspace": workspace}, nil)
}

func (c *Client) RenamePane(ctx context.Context, pane uint64, name string) error {
	return c.request(ctx, "rename-pane", map[string]any{"pane": pane, "name": name}, nil)
}

func (c *Client) RenameSurface(ctx context.Context, surface uint64, name string) error {
	return c.request(ctx, "rename-surface", map[string]any{"surface": surface, "name": name}, nil)
}

func (c *Client) RenameScreen(ctx context.Context, screen uint64, name string) error {
	return c.request(ctx, "rename-screen", map[string]any{"screen": screen, "name": name}, nil)
}

func (c *Client) RenameWorkspace(ctx context.Context, workspace uint64, name string) error {
	return c.request(ctx, "rename-workspace", map[string]any{"workspace": workspace, "name": name}, nil)
}

func (c *Client) ResizeSurface(ctx context.Context, surface uint64, cols, rows uint16) (ResizeSurfaceResult, error) {
	var result ResizeSurfaceResult
	err := c.request(ctx, "resize-surface", map[string]any{"surface": surface, "cols": cols, "rows": rows}, &result)
	return result, err
}

func (c *Client) FocusPane(ctx context.Context, pane uint64) error {
	return c.request(ctx, "focus-pane", map[string]any{"pane": pane}, nil)
}

func (c *Client) SelectTab(ctx context.Context, opts SelectTabOptions) error {
	return c.request(ctx, "select-tab", commandMap(opts), nil)
}

func (c *Client) SelectScreen(ctx context.Context, opts SelectOptions) error {
	return c.request(ctx, "select-screen", commandMap(opts), nil)
}

func (c *Client) SelectWorkspace(ctx context.Context, opts SelectOptions) error {
	return c.request(ctx, "select-workspace", commandMap(opts), nil)
}

func (c *Client) MoveTab(ctx context.Context, surface, pane uint64, index uint) error {
	return c.request(ctx, "move-tab", map[string]any{"surface": surface, "pane": pane, "index": index}, nil)
}

func (c *Client) MoveWorkspace(ctx context.Context, workspace uint64, index uint) error {
	return c.request(ctx, "move-workspace", map[string]any{"workspace": workspace, "index": index}, nil)
}

func (c *Client) MoveWorkspaceRegistry(ctx context.Context, opts WorkspaceSelectorOptions, index uint) (WorkspaceMutation, error) {
	if err := validateWorkspaceSelector(opts.Workspace, opts.Key); err != nil {
		return WorkspaceMutation{}, err
	}
	if err := c.requireCapability(ctx, "workspace-registry-v1", "workspace registry"); err != nil {
		return WorkspaceMutation{}, err
	}
	params := commandMap(opts)
	params["index"] = index
	var result WorkspaceMutation
	return result, c.request(ctx, "move-workspace", params, &result)
}

func (c *Client) RenameWorkspaceRegistry(ctx context.Context, opts WorkspaceSelectorOptions, name string) (WorkspaceMutation, error) {
	if err := validateWorkspaceSelector(opts.Workspace, opts.Key); err != nil {
		return WorkspaceMutation{}, err
	}
	if err := c.requireCapability(ctx, "workspace-registry-v1", "workspace registry"); err != nil {
		return WorkspaceMutation{}, err
	}
	params := commandMap(opts)
	params["name"] = name
	var result WorkspaceMutation
	return result, c.request(ctx, "rename-workspace", params, &result)
}

func (c *Client) CloseWorkspaceRegistry(ctx context.Context, opts WorkspaceSelectorOptions) (WorkspaceMutation, error) {
	var result WorkspaceMutation
	if err := validateWorkspaceSelector(opts.Workspace, opts.Key); err != nil {
		return result, err
	}
	if err := c.requireCapability(ctx, "workspace-registry-v1", "workspace registry"); err != nil {
		return result, err
	}
	return result, c.request(ctx, "close-workspace", commandMap(opts), &result)
}

func (c *Client) ScrollSurface(ctx context.Context, surface uint64, delta int) error {
	return c.request(ctx, "scroll-surface", map[string]any{"surface": surface, "delta": delta}, nil)
}

func (c *Client) Subscribe(ctx context.Context) (*Stream, error) {
	return c.openStream(ctx, map[string]any{"id": c.nextRequestID(), "cmd": "subscribe"})
}

type AttachSurfaceOptions struct {
	Cols *uint16
	Rows *uint16
}

func (c *Client) AttachSurface(ctx context.Context, surface uint64) (*Stream, error) {
	return c.AttachSurfaceWithOptions(ctx, surface, AttachSurfaceOptions{})
}

func (c *Client) AttachSurfaceWithOptions(ctx context.Context, surface uint64, opts AttachSurfaceOptions) (*Stream, error) {
	if (opts.Cols == nil) != (opts.Rows == nil) {
		return nil, fmt.Errorf("%w: attach-surface cols and rows must be supplied together", ErrInvalidArgument)
	}
	protocol, identified, _ := c.negotiatedState("")
	if !identified {
		if _, err := c.Identify(ctx); err != nil {
			return nil, err
		}
		protocol, _, _ = c.negotiatedState("")
	}
	if protocol > 5 && !c.allowProtocolV6Attach {
		return nil, &protocolError{msg: fmt.Sprintf("unsupported attach protocol %d", protocol)}
	}
	if (opts.Cols != nil || opts.Rows != nil) && !c.hasCapability("attach-initial-size") {
		return nil, &protocolError{msg: "initial attach sizing is not supported by this server"}
	}
	params := map[string]any{"id": c.nextRequestID(), "cmd": "attach-surface", "surface": surface}
	if opts.Cols != nil {
		params["cols"] = *opts.Cols
	}
	if opts.Rows != nil {
		params["rows"] = *opts.Rows
	}
	return c.openStream(ctx, params)
}

func (c *Client) hasCapability(capability string) bool {
	_, _, supported := c.negotiatedState(capability)
	return supported
}

func (c *Client) requireCapability(ctx context.Context, capability, feature string) error {
	_, identified, supported := c.negotiatedState(capability)
	if !identified {
		if _, err := c.Identify(ctx); err != nil {
			return err
		}
		_, _, supported = c.negotiatedState(capability)
	}
	if !supported {
		return &protocolError{msg: feature + " is not supported by this server"}
	}
	return nil
}

func (c *Client) negotiatedState(capability string) (uint32, bool, bool) {
	c.negotiationMu.RLock()
	defer c.negotiationMu.RUnlock()
	if c.protocol == nil {
		return 0, false, false
	}
	_, supported := c.capabilities[capability]
	return *c.protocol, true, supported
}

func (c *Client) openStream(ctx context.Context, request map[string]any) (*Stream, error) {
	conn, err := dialJSON(c.socketPath)
	if err != nil {
		return nil, err
	}
	if err := conn.Send(ctx, c.timeout, request); err != nil {
		_ = conn.Close()
		return nil, err
	}
	requestID := request["id"]
	var buffered []Event
	for {
		response, err := conn.Recv(ctx, c.timeout)
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		if _, ok := response["event"].(string); ok {
			buffered = append(buffered, parseEvent(response))
			continue
		}
		if !sameJSONValue(response["id"], requestID) {
			continue
		}
		if ok, _ := response["ok"].(bool); ok {
			return &Stream{conn: conn, timeout: c.timeout, buffered: buffered}, nil
		}
		msg, _ := response["error"].(string)
		if msg == "" {
			msg = "unknown error"
		}
		_ = conn.Close()
		return nil, &CommandError{Message: msg, ID: response["id"]}
	}
}

type Stream struct {
	conn     *jsonLineConn
	timeout  time.Duration
	buffered []Event
	closed   atomic.Bool
}

func (s *Stream) Close() error {
	if !s.closed.CompareAndSwap(false, true) {
		return nil
	}
	return s.conn.Close()
}

func (s *Stream) Recv(ctx context.Context) (Event, error) {
	if s.closed.Load() {
		return nil, io.EOF
	}
	if len(s.buffered) > 0 {
		event := s.buffered[0]
		s.buffered = s.buffered[1:]
		return s.finishTerminal(event), nil
	}
	for {
		value, err := s.conn.Recv(ctx, s.timeout)
		if err != nil {
			return nil, err
		}
		if _, ok := value["event"].(string); ok {
			return s.finishTerminal(parseEvent(value)), nil
		}
	}
}

func (s *Stream) finishTerminal(event Event) Event {
	switch event.(type) {
	case DetachedEvent, OverflowEvent:
		_ = s.Close()
	}
	return event
}

type jsonLineConn struct {
	conn   net.Conn
	reader *bufio.Reader
	sendMu sync.Mutex
	readMu sync.Mutex
}

func dialJSON(socketPath string) (*jsonLineConn, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, &connectionError{msg: fmt.Sprintf("cannot connect to session socket %s: %v", socketPath, err)}
	}
	return &jsonLineConn{conn: conn, reader: bufio.NewReader(conn)}, nil
}

func (c *jsonLineConn) Close() error {
	return c.conn.Close()
}

func (c *jsonLineConn) Send(ctx context.Context, timeout time.Duration, value map[string]any) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if err := setWriteDeadline(ctx, c.conn, timeout); err != nil {
		return err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return &decodeError{msg: err.Error()}
	}
	encoded = append(encoded, '\n')
	if _, err := c.conn.Write(encoded); err != nil {
		return classifyNetError(err, "socket write failed")
	}
	return nil
}

func (c *jsonLineConn) Recv(ctx context.Context, timeout time.Duration) (map[string]any, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if err := ctx.Err(); err != nil {
			return nil, &timeoutError{msg: err.Error()}
		}
		deadline := time.Now().Add(timeout)
		if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
			deadline = ctxDeadline
		}
		if err := c.conn.SetReadDeadline(deadline); err != nil {
			return nil, &connectionError{msg: err.Error()}
		}
		line, err := c.reader.ReadBytes('\n')
		if err != nil {
			return nil, classifyNetError(err, "socket read failed")
		}
		var value map[string]any
		if err := json.Unmarshal(line, &value); err != nil {
			return nil, &decodeError{msg: err.Error()}
		}
		return value, nil
	}
}

func setWriteDeadline(ctx context.Context, conn net.Conn, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	if err := conn.SetWriteDeadline(deadline); err != nil {
		return &connectionError{msg: err.Error()}
	}
	return nil
}

func classifyNetError(err error, prefix string) error {
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return &timeoutError{msg: "session did not respond"}
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return &timeoutError{msg: "session did not respond"}
	}
	return &connectionError{msg: fmt.Sprintf("%s: %v", prefix, err)}
}

func commandMap(value any) map[string]any {
	encoded, _ := json.Marshal(value)
	out := map[string]any{}
	_ = json.Unmarshal(encoded, &out)
	for key, item := range out {
		if item == nil {
			delete(out, key)
		}
	}
	return out
}

func sameJSONValue(a, b any) bool {
	aa, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return string(aa) == string(bb)
}
