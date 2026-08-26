package raw

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/manaflow-ai/cmux/cmux-tui/bindings/go/internal/sessionpath"
)

const (
	// MaxRequestBytes is the maximum encoded client message size. The
	// JSON-lines delimiter is excluded.
	MaxRequestBytes = 4 * 1024 * 1024
	// MaxResponseBytes is the maximum encoded server message size. The
	// JSON-lines delimiter is excluded.
	MaxResponseBytes = 16 * 1024 * 1024
	// MaxBufferedStreamEvents matches the server's per-stream event backlog.
	MaxBufferedStreamEvents = 4096
)

var (
	ErrCommand          = errors.New("cmux-tui command error")
	ErrConnection       = errors.New("cmux-tui connection error")
	ErrTimeout          = errors.New("cmux-tui timeout")
	ErrProtocolMismatch = errors.New("cmux-tui protocol mismatch")
	ErrDecode           = errors.New("cmux-tui decode error")
	ErrInvalidArgument  = errors.New("cmux-tui invalid argument")
	ErrMessageTooLarge  = errors.New("cmux-tui message too large")
	ErrBufferFull       = errors.New("cmux-tui stream buffer full")
	ErrAuthority        = errors.New("cmux-tui authority denied")
)

type CommandError struct {
	Message string
	ID      any
}

func (e *CommandError) Error() string { return e.Message }
func (e *CommandError) Is(target error) bool {
	return target == ErrCommand
}

type connectionError struct {
	msg   string
	cause error
}

func (e *connectionError) Error() string { return e.msg }
func (e *connectionError) Unwrap() error { return e.cause }
func (e *connectionError) Is(target error) bool {
	return target == ErrConnection
}

type timeoutError struct {
	msg   string
	cause error
}

func (e *timeoutError) Error() string { return e.msg }
func (e *timeoutError) Is(target error) bool {
	return target == ErrTimeout
}
func (e *timeoutError) Unwrap() error { return e.cause }

// AuthorityError reports a generated command rejected by the client's local
// authority policy before any bytes were written to the session socket.
type AuthorityError struct {
	Command  string
	Required Authority
}

func (e *AuthorityError) Error() string {
	return fmt.Sprintf("%s requires %s authority", e.Command, e.Required)
}
func (e *AuthorityError) Is(target error) bool {
	return target == ErrAuthority
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

// Client serializes command calls over one Unix connection. Streams use
// dedicated connections so closing a stream cancels only that local reader.
type Client struct {
	socketPath              string
	timeout                 time.Duration
	maxRequestBytes         int
	maxResponseBytes        int
	maxBufferedStreamEvents int
	conn                    *jsonLineConn
	mu                      sync.Mutex
	nextID                  atomic.Uint64
	negotiationMu           sync.RWMutex
	protocol                *uint32
	capabilities            map[string]struct{}
	enableProviderAuthority bool
}

type Options struct {
	SocketPath string
	Session    string
	// SessionSet distinguishes an explicitly supplied Session from omission.
	// When false, an empty Session selects "main". When true, an empty Session
	// is invalid if socket discovery needs a session name.
	SessionSet bool
	Timeout    time.Duration

	// MaxRequestBytes, MaxResponseBytes, and MaxBufferedStreamEvents set
	// per-client safety limits. Zero uses the corresponding package default.
	MaxRequestBytes         int
	MaxResponseBytes        int
	MaxBufferedStreamEvents int

	// EnableProviderAuthority permits provider-owned workspace mutations.
	// Ordinary Unix clients allow control, frontend, and local-admin commands
	// by default, but provider authority requires this explicit opt-in.
	EnableProviderAuthority bool

	// AllowProtocolV6Attach is retained for source compatibility. Current byte,
	// render, and browser attachments work without an opt-in.
	//
	// Deprecated: this option no longer changes behavior.
	AllowProtocolV6Attach bool
}

func NewClient(options Options) (*Client, error) {
	session := options.Session
	if session == "" && !options.SessionSet {
		session = "main"
	}
	socketPath, err := ResolveSocketPath(options.SocketPath, session)
	if err != nil {
		return nil, err
	}
	timeout := options.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	if timeout < 0 {
		return nil, fmt.Errorf("%w: timeout must not be negative", ErrInvalidArgument)
	}
	maxRequestBytes, err := optionLimit(
		"MaxRequestBytes",
		options.MaxRequestBytes,
		MaxRequestBytes,
	)
	if err != nil {
		return nil, err
	}
	maxResponseBytes, err := optionLimit(
		"MaxResponseBytes",
		options.MaxResponseBytes,
		MaxResponseBytes,
	)
	if err != nil {
		return nil, err
	}
	maxBufferedStreamEvents, err := optionLimit(
		"MaxBufferedStreamEvents",
		options.MaxBufferedStreamEvents,
		MaxBufferedStreamEvents,
	)
	if err != nil {
		return nil, err
	}
	legacy := ""
	if options.SocketPath == "" && EnvSocketPath() == "" {
		legacy = legacySocketPathForResolvedSession(socketPath, session)
	}
	conn, effective, err := dialJSONWithFallback(
		socketPath,
		legacy,
		maxRequestBytes,
		maxResponseBytes,
		timeout,
	)
	if err != nil {
		return nil, err
	}
	return &Client{
		socketPath:              effective,
		timeout:                 timeout,
		maxRequestBytes:         maxRequestBytes,
		maxResponseBytes:        maxResponseBytes,
		maxBufferedStreamEvents: maxBufferedStreamEvents,
		conn:                    conn,
		enableProviderAuthority: options.EnableProviderAuthority,
	}, nil
}

func optionLimit(name string, value, defaultValue int) (int, error) {
	if value < 0 {
		return 0, fmt.Errorf("%w: %s must not be negative", ErrInvalidArgument, name)
	}
	if value == 0 {
		return defaultValue, nil
	}
	return value, nil
}

// ResolveSocketPath applies the normative explicit, environment, and runtime
// directory discovery order.
func ResolveSocketPath(explicit, session string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	if socketPath := EnvSocketPath(); socketPath != "" {
		return socketPath, nil
	}
	if err := ValidateSession(session); err != nil {
		return "", err
	}
	return DefaultSocketPath(session), nil
}

// ValidateSession rejects names that could escape the private runtime
// directory or carry control text into the socket path.
func ValidateSession(session string) error {
	if err := sessionpath.Validate(session); err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidArgument, err)
	}
	return nil
}

func DefaultSocketPath(session string) string {
	if err := ValidateSession(session); err != nil {
		return invalidSessionSocketPath(session)
	}
	base := firstNonEmptyEnv("XDG_RUNTIME_DIR", "TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	fileName := session + ".sock"
	preferred := filepath.Join(base, fmt.Sprintf("cmux-tui-%d", os.Getuid()), fileName)
	if unixSocketPathFits(preferred) {
		return preferred
	}
	if base != "/tmp" {
		fallback := filepath.Join("/tmp", fmt.Sprintf("cmux-tui-%d", os.Getuid()), fileName)
		if unixSocketPathFits(fallback) {
			return fallback
		}
	}
	hashed := filepath.Join(
		base,
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
		sessionpath.Digest(session)+".sock",
	)
	if unixSocketPathFits(hashed) {
		return hashed
	}
	return filepath.Join(
		"/tmp",
		fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid()),
		sessionpath.Digest(session)+".sock",
	)
}

func legacySocketPathForSession(session string) string {
	path := filepath.Join("/tmp", "cmux-tui-"+strconv.Itoa(os.Getuid()), session+".sock")
	if unixSocketPathFits(path) {
		return path
	}
	return ""
}

func legacySocketPathForResolvedSession(resolved, session string) string {
	if runtime.GOOS == "windows" {
		return ""
	}
	base := firstNonEmptyEnv("XDG_RUNTIME_DIR", "TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	leaf := sessionpath.Digest(session) + ".sock"
	uid := fmt.Sprintf("cmux-tui-hashed-%d", os.Getuid())
	preferredHashed := filepath.Join(base, uid, leaf)
	tmpHashed := filepath.Join("/tmp", uid, leaf)
	if resolved != preferredHashed && resolved != tmpHashed {
		return ""
	}
	return legacySocketPathForSession(session)
}

// invalidSessionSocketPath is retained for source-compatible path queries.
// It is not a connector route. New clients must use ResolveSocketPath, which
// returns ErrInvalidArgument before any path is opened.
func invalidSessionSocketPath(session string) string {
	base := firstNonEmptyEnv("XDG_RUNTIME_DIR", "TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	leaf := sessionpath.Digest(session) + ".sock"
	preferred := filepath.Join(
		base,
		fmt.Sprintf("cmux-tui-invalid-%d", os.Getuid()),
		leaf,
	)
	if unixSocketPathFits(preferred) {
		return preferred
	}
	return filepath.Join("/tmp", fmt.Sprintf("cmux-tui-invalid-%d", os.Getuid()), leaf)
}

func EnvSocketPath() string {
	if socketPath := os.Getenv("CMUX_TUI_SOCKET"); socketPath != "" {
		return socketPath
	}
	return os.Getenv("CMUX_MUX_SOCKET")
}

func firstNonEmptyEnv(names ...string) string {
	for _, name := range names {
		if value := os.Getenv(name); value != "" {
			return value
		}
	}
	return ""
}

func unixSocketPathFits(path string) bool {
	return len([]byte(path)) < unixSocketPathCapacity(runtime.GOOS)
}

func unixSocketPathCapacity(goos string) int {
	switch goos {
	case "darwin", "dragonfly", "freebsd", "netbsd", "openbsd":
		return 104
	default:
		return 108
	}
}

func (c *Client) Close() error {
	if c == nil || c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// SendRaw is the forward-compatible request escape hatch. It preserves exact
// integers as json.Number values in the returned response envelope.
func (c *Client) SendRaw(
	ctx context.Context,
	requestValue map[string]any,
) (map[string]any, error) {
	if command, ok := requestValue["cmd"].(string); ok {
		if metadata, known := commandMetadata[command]; known {
			if err := c.checkAuthority(metadata); err != nil {
				return nil, err
			}
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil {
		return nil, &connectionError{msg: "client is not connected"}
	}
	request := make(map[string]any, len(requestValue)+1)
	for key, value := range requestValue {
		request[key] = value
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

func (c *Client) request(
	ctx context.Context,
	command string,
	params map[string]any,
	out any,
) error {
	if params == nil {
		params = map[string]any{}
	}
	params["id"] = c.nextRequestID()
	params["cmd"] = command
	response, err := c.SendRaw(ctx, params)
	if err != nil {
		return err
	}
	if ok, _ := response["ok"].(bool); ok {
		if out == nil {
			return nil
		}
		encoded, err := json.Marshal(response["data"])
		if err != nil {
			return &decodeError{msg: err.Error()}
		}
		if err := decodeJSON(encoded, out); err != nil {
			return &decodeError{msg: err.Error()}
		}
		return nil
	}
	message, _ := response["error"].(string)
	if message == "" {
		message = "unknown error"
	}
	return &CommandError{Message: message, ID: response["id"]}
}

func (c *Client) requestGenerated(
	ctx context.Context,
	metadata CommandMetadata,
	command string,
	params map[string]any,
	out any,
) error {
	if err := c.checkAuthority(metadata); err != nil {
		return err
	}
	if err := c.requireGeneratedCompatibility(ctx, metadata, params); err != nil {
		return err
	}
	if err := c.request(ctx, command, params, out); err != nil {
		return err
	}
	if command == "identify" {
		if result, ok := out.(*IdentifyResult); ok {
			c.rememberNegotiation(result.Protocol, result.Capabilities)
		}
	}
	return nil
}

func (c *Client) checkAuthority(metadata CommandMetadata) error {
	switch metadata.Authority {
	case AuthorityControl, AuthorityFrontend, AuthorityLocalAdmin:
		return nil
	case AuthorityProviderAuthority:
		if c.enableProviderAuthority {
			return nil
		}
	}
	return &AuthorityError{
		Command:  metadata.Name,
		Required: metadata.Authority,
	}
}

func (c *Client) requireGeneratedCompatibility(
	ctx context.Context,
	metadata CommandMetadata,
	params map[string]any,
) error {
	if metadata.Name != "identify" && metadata.Since > 5 {
		if err := c.requireProtocol(ctx, metadata.Since, metadata.Name); err != nil {
			return err
		}
	}
	if metadata.Capability != "" {
		if err := c.requireCapability(
			ctx,
			metadata.Capability,
			metadata.Name,
		); err != nil {
			return err
		}
	}
	fields := make([]string, 0, len(params))
	for field := range params {
		fields = append(fields, field)
	}
	sort.Strings(fields)
	for _, field := range fields {
		feature := metadata.Name + "." + field
		if since := metadata.FieldSince[field]; since > 5 {
			if err := c.requireProtocol(ctx, since, feature); err != nil {
				return err
			}
		}
		if capability := metadata.FieldCapabilities[field]; capability != "" {
			if err := c.requireCapability(ctx, capability, feature); err != nil {
				return err
			}
		}
	}
	return nil
}

func (c *Client) nextRequestID() uint64 {
	return c.nextID.Add(1)
}

func (c *Client) rememberNegotiation(protocol uint32, values *[]string) {
	capabilities := make(map[string]struct{})
	if values != nil {
		for _, capability := range *values {
			capabilities[capability] = struct{}{}
		}
	}
	c.negotiationMu.Lock()
	c.protocol = &protocol
	c.capabilities = capabilities
	c.negotiationMu.Unlock()
}

// IdentifyDetailed is retained as a compatibility spelling.
func (c *Client) IdentifyDetailed(ctx context.Context) (IdentifyDetails, error) {
	return c.Identify(ctx)
}

func (c *Client) requireProtocol(
	ctx context.Context,
	minimum uint32,
	feature string,
) error {
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
			feature,
			minimum,
			protocol,
		)}
	}
	return nil
}

func (c *Client) hasCapability(capability string) bool {
	_, _, supported := c.negotiatedState(capability)
	return supported
}

func (c *Client) requireCapability(
	ctx context.Context,
	capability string,
	feature string,
) error {
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

// Send preserves the exact text, base64 bytes, and paste presence represented
// by SendOptions.
func (c *Client) Send(
	ctx context.Context,
	surface ID,
	options SendOptions,
) error {
	params := map[string]any{"surface": surface}
	if options.Text.IsNull() {
		params["text"] = nil
	} else if text, ok := options.Text.Get(); ok {
		params["text"] = text
	}
	if options.Bytes.IsNull() {
		params["bytes"] = nil
	} else if encoded, ok := options.Bytes.Get(); ok {
		params["bytes"] = encoded
	}
	if options.Paste != nil {
		params["paste"] = *options.Paste
	}
	return c.requestGenerated(
		ctx,
		commandMetadata["send"],
		"send",
		params,
		nil,
	)
}

func (c *Client) UseOnlyClientSize(
	ctx context.Context,
	surface ID,
	client uint64,
) error {
	exclusive := true
	return c.SetClientSizing(
		ctx,
		surface,
		true,
		SetClientSizingOptions{
			Client:    Value(client),
			Exclusive: &exclusive,
		},
	)
}

func (c *Client) UseAllClientSizes(ctx context.Context, surface ID) error {
	return c.SetClientSizing(ctx, surface, true, SetClientSizingOptions{})
}

// VtState is retained for source compatibility with the pre-generator name.
func (c *Client) VtState(ctx context.Context, surface ID) (VTStateResult, error) {
	return c.VTState(ctx, surface)
}

// CloseWorkspaceByID is the concise numeric-id form of CloseWorkspace.
func (c *Client) CloseWorkspaceByID(
	ctx context.Context,
	workspace ID,
) (CloseWorkspaceResult, error) {
	return c.CloseWorkspace(
		ctx,
		CloseWorkspaceOptions{Workspace: Value(workspace)},
	)
}

func (c *Client) Subscribe(ctx context.Context) (*Stream, error) {
	return c.SubscribeWithOptions(ctx, SubscribeOptions{})
}

func (c *Client) SubscribeDeltas(ctx context.Context) (*Stream, error) {
	return c.SubscribeWithOptions(
		ctx,
		SubscribeOptions{TreeEvents: Value(TreeEventsDeltas)},
	)
}

func (c *Client) SubscribeWithOptions(
	ctx context.Context,
	options SubscribeOptions,
) (*Stream, error) {
	params := map[string]any{"id": c.nextRequestID(), "cmd": "subscribe"}
	if options.TreeEvents.IsNull() {
		params["tree_events"] = nil
	} else if treeEvents, ok := options.TreeEvents.Get(); ok {
		switch treeEvents {
		case TreeEventsCoarse, TreeEventsDeltas:
			params["tree_events"] = string(treeEvents)
		default:
			return nil, fmt.Errorf(
				"%w: unsupported tree event mode %q",
				ErrInvalidArgument,
				treeEvents,
			)
		}
	}
	if options.Surface.IsNull() {
		params["surface"] = nil
	} else if surface, ok := options.Surface.Get(); ok {
		params["surface"] = surface
	}
	return c.openGeneratedStream(ctx, commandMetadata["subscribe"], params)
}

func (c *Client) AttachSurface(
	ctx context.Context,
	surface ID,
) (*Stream, error) {
	return c.AttachSurfaceWithOptions(ctx, surface, AttachSurfaceOptions{})
}

func (c *Client) AttachSurfaceWithOptions(
	ctx context.Context,
	surface ID,
	options AttachSurfaceOptions,
) (*Stream, error) {
	if options.Cols.IsAbsent() != options.Rows.IsAbsent() {
		return nil, fmt.Errorf(
			"%w: attach-surface cols and rows must be supplied together",
			ErrInvalidArgument,
		)
	}
	params := map[string]any{
		"id":      c.nextRequestID(),
		"cmd":     "attach-surface",
		"surface": surface,
	}
	if options.Mode.IsNull() {
		params["mode"] = nil
	} else if mode, ok := options.Mode.Get(); ok {
		switch mode {
		case AttachBytes, AttachRender:
			params["mode"] = string(mode)
		default:
			return nil, fmt.Errorf(
				"%w: unsupported attach mode %q",
				ErrInvalidArgument,
				mode,
			)
		}
	}
	if options.Cols.IsNull() {
		params["cols"] = nil
	} else if cols, ok := options.Cols.Get(); ok {
		params["cols"] = cols
	}
	if options.Rows.IsNull() {
		params["rows"] = nil
	} else if rows, ok := options.Rows.Get(); ok {
		params["rows"] = rows
	}
	return c.openGeneratedStream(ctx, commandMetadata["attach-surface"], params)
}

func (c *Client) openGeneratedStream(
	ctx context.Context,
	metadata CommandMetadata,
	request map[string]any,
) (*Stream, error) {
	if err := c.checkAuthority(metadata); err != nil {
		return nil, err
	}
	if err := c.requireGeneratedCompatibility(ctx, metadata, request); err != nil {
		return nil, err
	}
	return c.openStream(ctx, request)
}

func (c *Client) openStream(
	ctx context.Context,
	request map[string]any,
) (*Stream, error) {
	conn, _, err := dialJSONWithFallback(
		c.socketPath,
		"",
		c.requestLimit(),
		c.responseLimit(),
		c.timeout,
	)
	if err != nil {
		return nil, err
	}
	if err := conn.Send(ctx, c.timeout, request); err != nil {
		_ = conn.Close()
		return nil, err
	}
	requestID := request["id"]
	buffered := make([]Event, 0, 1)
	for {
		response, err := conn.Recv(ctx, c.timeout)
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		if _, ok := response["event"].(string); ok {
			eventLimit := c.streamEventLimit()
			if len(buffered) >= eventLimit {
				_ = conn.Close()
				return nil, fmt.Errorf(
					"%w: more than %d events arrived before the stream response",
					ErrBufferFull,
					eventLimit,
				)
			}
			buffered = append(buffered, parseEvent(response))
			continue
		}
		if !sameJSONValue(response["id"], requestID) {
			continue
		}
		if ok, _ := response["ok"].(bool); ok {
			return &Stream{conn: conn, timeout: c.timeout, buffered: buffered}, nil
		}
		message, _ := response["error"].(string)
		if message == "" {
			message = "unknown error"
		}
		_ = conn.Close()
		return nil, &CommandError{Message: message, ID: response["id"]}
	}
}

func (c *Client) requestLimit() int {
	if c.maxRequestBytes == 0 {
		return MaxRequestBytes
	}
	return c.maxRequestBytes
}

func (c *Client) responseLimit() int {
	if c.maxResponseBytes == 0 {
		return MaxResponseBytes
	}
	return c.maxResponseBytes
}

func (c *Client) streamEventLimit() int {
	if c.maxBufferedStreamEvents == 0 {
		return MaxBufferedStreamEvents
	}
	return c.maxBufferedStreamEvents
}

// Stream is a dedicated subscribe or attach transport. Close is concurrent
// safe and unblocks Recv.
type Stream struct {
	conn     *jsonLineConn
	timeout  time.Duration
	buffered []Event
	closed   atomic.Bool
}

func (s *Stream) Close() error {
	if s == nil || s.conn == nil || !s.closed.CompareAndSwap(false, true) {
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
			if s.closed.Load() && errors.Is(err, ErrConnection) {
				return nil, io.EOF
			}
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
	conn             net.Conn
	reader           *bufio.Reader
	maxRequestBytes  int
	maxResponseBytes int
	sendMu           sync.Mutex
	readMu           sync.Mutex
	closeOnce        sync.Once
	closeErr         error
}

func dialJSON(
	socketPath string,
	maxRequestBytes int,
	maxResponseBytes int,
	timeout time.Duration,
) (*jsonLineConn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return dialJSONContext(ctx, socketPath, maxRequestBytes, maxResponseBytes)
}

var dialUnixContext = func(ctx context.Context, socketPath string) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
}

func dialJSONContext(
	ctx context.Context,
	socketPath string,
	maxRequestBytes int,
	maxResponseBytes int,
) (*jsonLineConn, error) {
	conn, err := dialUnixContext(ctx, socketPath)
	if err != nil {
		return nil, &connectionError{cause: err, msg: fmt.Sprintf(
			"cannot connect to session socket %s: %v",
			socketPath,
			err,
		)}
	}
	return &jsonLineConn{
		conn:             conn,
		reader:           bufio.NewReader(conn),
		maxRequestBytes:  maxRequestBytes,
		maxResponseBytes: maxResponseBytes,
	}, nil
}

func dialJSONWithFallback(
	path, legacy string,
	req, resp int,
	timeout time.Duration,
) (*jsonLineConn, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := dialJSONContext(ctx, path, req, resp)
	if err == nil {
		return conn, path, nil
	}
	if legacy == "" || (!errors.Is(err, syscall.ENOENT) && !errors.Is(err, syscall.ECONNREFUSED)) {
		return nil, path, err
	}
	conn, fallbackErr := dialJSONContext(ctx, legacy, req, resp)
	if fallbackErr != nil {
		return nil, path, fallbackErr
	}
	return conn, legacy, nil
}

func (c *jsonLineConn) Close() error {
	c.closeOnce.Do(func() {
		c.closeErr = c.conn.Close()
	})
	return c.closeErr
}

func (c *jsonLineConn) Send(
	ctx context.Context,
	timeout time.Duration,
	value map[string]any,
) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if err := timeoutFromContext(ctx); err != nil {
		return err
	}
	if err := setWriteDeadline(ctx, c.conn, timeout); err != nil {
		return err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return &decodeError{msg: err.Error()}
	}
	maximum := c.maxRequestBytes
	if maximum == 0 {
		maximum = MaxRequestBytes
	}
	if len(encoded) > maximum {
		return fmt.Errorf(
			"%w: request is %d bytes, maximum is %d",
			ErrMessageTooLarge,
			len(encoded),
			maximum,
		)
	}
	if !utf8.Valid(encoded) {
		return &decodeError{msg: "request is not valid UTF-8"}
	}
	encoded = append(encoded, '\n')
	cancelDeadline := context.AfterFunc(ctx, func() {
		_ = c.conn.SetWriteDeadline(time.Now())
	})
	err = writeAll(c.conn, encoded)
	cancelDeadline()
	if err != nil {
		if contextError := timeoutFromContext(ctx); contextError != nil {
			return contextError
		}
		return classifyNetError(err, "socket write failed")
	}
	return nil
}

func (c *jsonLineConn) Recv(
	ctx context.Context,
	timeout time.Duration,
) (map[string]any, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	if err := timeoutFromContext(ctx); err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := c.conn.SetReadDeadline(deadline); err != nil {
		return nil, &connectionError{msg: err.Error()}
	}
	cancelDeadline := context.AfterFunc(ctx, func() {
		_ = c.conn.SetReadDeadline(time.Now())
	})
	maximum := c.maxResponseBytes
	if maximum == 0 {
		maximum = MaxResponseBytes
	}
	line, err := readBoundedLine(c.reader, maximum)
	cancelDeadline()
	if err != nil {
		if contextError := timeoutFromContext(ctx); contextError != nil {
			return nil, contextError
		}
		if errors.Is(err, ErrMessageTooLarge) {
			_ = c.Close()
			return nil, err
		}
		return nil, classifyNetError(err, "socket read failed")
	}
	if !utf8.Valid(line) {
		_ = c.Close()
		return nil, &decodeError{msg: "response is not valid UTF-8"}
	}
	var value map[string]any
	if err := decodeJSON(line, &value); err != nil {
		_ = c.Close()
		return nil, &decodeError{msg: err.Error()}
	}
	return value, nil
}

func timeoutFromContext(ctx context.Context) *timeoutError {
	if err := ctx.Err(); err != nil {
		return &timeoutError{msg: err.Error(), cause: err}
	}
	if deadline, ok := ctx.Deadline(); ok && !time.Now().Before(deadline) {
		return &timeoutError{
			msg:   context.DeadlineExceeded.Error(),
			cause: context.DeadlineExceeded,
		}
	}
	return nil
}

func setWriteDeadline(
	ctx context.Context,
	conn net.Conn,
	timeout time.Duration,
) error {
	deadline := time.Now().Add(timeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
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
	var netError net.Error
	if errors.As(err, &netError) && netError.Timeout() {
		return &timeoutError{msg: "session did not respond"}
	}
	return &connectionError{msg: fmt.Sprintf("%s: %v", prefix, err)}
}

func mergeCommandParams(base map[string]any, value any) (map[string]any, error) {
	options, err := commandMap(value)
	if err != nil {
		return nil, err
	}
	for key, item := range options {
		base[key] = item
	}
	return base, nil
}

func commandMap(value any) (map[string]any, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if err := decodeJSON(encoded, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func decodeEvent(raw map[string]any, out any) bool {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return false
	}
	return decodeJSON(encoded, out) == nil
}

func decodeJSON(data []byte, out any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(out); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values in one message")
		}
		return err
	}
	return nil
}

func readBoundedLine(reader *bufio.Reader, maximum int) ([]byte, error) {
	var line []byte
	for {
		fragment, err := reader.ReadSlice('\n')
		if len(line)+len(fragment) > maximum+1 {
			return nil, fmt.Errorf(
				"%w: response exceeds %d bytes",
				ErrMessageTooLarge,
				maximum,
			)
		}
		line = append(line, fragment...)
		if err == nil {
			line = line[:len(line)-1]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			return line, nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if written < 0 || written > len(data) {
			return errors.New("writer returned an invalid count")
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}

func sameJSONValue(a, b any) bool {
	first, _ := json.Marshal(a)
	second, _ := json.Marshal(b)
	return string(first) == string(second)
}
