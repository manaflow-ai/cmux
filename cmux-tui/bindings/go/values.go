package cmux

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
)

type Command interface {
	command()
	validate() error
}

// ExactCommand preserves argv exactly. No field is interpreted by a shell.
type ExactCommand struct {
	Argv []string
}

func Exact(argv ...string) ExactCommand {
	return ExactCommand{Argv: append([]string(nil), argv...)}
}

// ShellCommand asks the server to use its platform shell.
type ShellCommand struct {
	Script string
}

func Shell(script string) ShellCommand { return ShellCommand{Script: script} }

// ExplicitShell is exact argv for callers that deliberately choose a shell.
func ExplicitShell(executable, script string) ExactCommand {
	return Exact(executable, "-lc", script)
}

func (ExactCommand) command() {}
func (ShellCommand) command() {}

func (c ExactCommand) validate() error {
	if len(c.Argv) == 0 {
		return fmt.Errorf("%w: argv must contain an executable", ErrInvalidArgument)
	}
	for _, argument := range c.Argv {
		if argument == "" && len(c.Argv) == 1 {
			return fmt.Errorf("%w: executable must not be empty", ErrInvalidArgument)
		}
	}
	return nil
}

func (c ShellCommand) validate() error {
	if c.Script == "" {
		return fmt.Errorf("%w: shell script must not be empty", ErrInvalidArgument)
	}
	return nil
}

type Direction string

const (
	DirectionLeft  Direction = "left"
	DirectionRight Direction = "right"
	DirectionUp    Direction = "up"
	DirectionDown  Direction = "down"
)

type MouseInput struct {
	Kind      string   `json:"kind"`
	X         float64  `json:"x,omitempty"`
	Y         float64  `json:"y,omitempty"`
	Button    string   `json:"button,omitempty"`
	Modifiers []string `json:"modifiers,omitempty"`
}

type KeyInput struct {
	Key       string   `json:"key"`
	Action    string   `json:"action,omitempty"`
	Modifiers []string `json:"modifiers,omitempty"`
	Text      string   `json:"text,omitempty"`
}

// Decimal is a protocol unsigned decimal. It is encoded as a JSON string so
// the full uint64 range survives transports whose native number type is
// narrower.
type Decimal uint64

func (d Decimal) String() string { return strconv.FormatUint(uint64(d), 10) }

func (d Decimal) Uint64() uint64 { return uint64(d) }

func (d Decimal) MarshalJSON() ([]byte, error) {
	return json.Marshal(d.String())
}

func (d *Decimal) UnmarshalJSON(data []byte) error {
	var encoded string
	if err := json.Unmarshal(data, &encoded); err != nil {
		return fmt.Errorf("cmux decimal must be a JSON string: %w", err)
	}
	if encoded == "" || len(encoded) > 20 || encoded[0] == '+' ||
		(len(encoded) > 1 && encoded[0] == '0') {
		return fmt.Errorf("cmux decimal %q is not canonical", encoded)
	}
	value, err := strconv.ParseUint(encoded, 10, 64)
	if err != nil {
		return fmt.Errorf("cmux decimal %q is outside uint64: %w", encoded, err)
	}
	*d = Decimal(value)
	return nil
}

func parseDecimal(value any, field string) (Decimal, error) {
	encoded, ok := value.(string)
	if !ok {
		return 0, &ProtocolError{Message: field + " must be a decimal string"}
	}
	raw, _ := json.Marshal(encoded)
	var result Decimal
	if err := result.UnmarshalJSON(raw); err != nil {
		return 0, &ProtocolError{Message: "invalid " + field + ": " + err.Error()}
	}
	return result, nil
}

type Cursor struct {
	Generation string  `json:"generation"`
	Revision   Decimal `json:"revision"`
}

func (c *Cursor) UnmarshalJSON(data []byte) error {
	var wire struct {
		Generation *string  `json:"generation"`
		Revision   *Decimal `json:"revision"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return err
	}
	if wire.Generation == nil || len(*wire.Generation) < 1 ||
		len(*wire.Generation) > 128 || wire.Revision == nil {
		return fmt.Errorf(
			"cursor requires a 1 to 128 character generation and revision",
		)
	}
	*c = Cursor{Generation: *wire.Generation, Revision: *wire.Revision}
	return nil
}

type MutationResult[T any] struct {
	Value      T
	Generation string
	Revision   Decimal
	Replayed   bool
}

// JSONValue marks catalog fields that intentionally accept arbitrary JSON.
// Decoding uses json.Number so integers are never silently rounded.
type JSONValue = any

type EmptyResult struct{}

type MutationReceipt = MutationResult[EmptyResult]

type StreamOpened struct {
	StreamID StreamID `json:"stream_id"`
	Cursor   *Cursor  `json:"cursor,omitempty"`
}

type ViewAttachmentStreamOpened struct {
	StreamID        StreamID `json:"stream_id"`
	AttachmentLease string   `json:"attachment_lease"`
}

type CreationResolutionState string

const (
	CreationResolutionPending       CreationResolutionState = "pending"
	CreationResolutionCreated       CreationResolutionState = "created"
	CreationResolutionNotApplied    CreationResolutionState = "not_applied"
	CreationResolutionIndeterminate CreationResolutionState = "indeterminate"
)

type CreationRecovery string

const (
	CreationRetrySameIdempotencyKey CreationRecovery = "retry_same_idempotency_key"
	CreationRetryNewIdempotencyKey  CreationRecovery = "retry_new_idempotency_key"
	CreationWait                    CreationRecovery = "wait"
	CreationNoRecovery              CreationRecovery = "none"
	CreationDoNotRetry              CreationRecovery = "do_not_retry"
)

type CreationResolution struct {
	CorrelationKey string                  `json:"correlation_key"`
	State          CreationResolutionState `json:"state"`
	Recovery       CreationRecovery        `json:"recovery"`
	Operation      *string                 `json:"operation,omitempty"`
	IdempotencyKey *string                 `json:"idempotency_key,omitempty"`
	CreatedPath    *CreatedPath            `json:"created_path,omitempty"`
	Generation     *string                 `json:"generation,omitempty"`
	Revision       *Decimal                `json:"revision,omitempty"`
}

func (r *CreationResolution) UnmarshalJSON(data []byte) error {
	var wire struct {
		CorrelationKey *string                  `json:"correlation_key"`
		State          *CreationResolutionState `json:"state"`
		Recovery       *CreationRecovery        `json:"recovery"`
		Operation      *string                  `json:"operation,omitempty"`
		IdempotencyKey *string                  `json:"idempotency_key,omitempty"`
		CreatedPath    *CreatedPath             `json:"created_path,omitempty"`
		Generation     *string                  `json:"generation,omitempty"`
		Revision       *Decimal                 `json:"revision,omitempty"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, field := range []string{
		"operation", "idempotency_key", "created_path", "generation", "revision",
	} {
		if raw, ok := fields[field]; ok &&
			bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("creation resolution %s cannot be null", field)
		}
	}
	if wire.CorrelationKey == nil ||
		len(*wire.CorrelationKey) < 1 || len(*wire.CorrelationKey) > 128 {
		return fmt.Errorf(
			"creation resolution requires a 1 to 128 character correlation_key",
		)
	}
	if wire.State == nil || wire.Recovery == nil {
		return fmt.Errorf("creation resolution requires state and recovery")
	}
	if wire.Operation != nil && *wire.Operation == "" {
		return fmt.Errorf("creation resolution operation must be non-empty")
	}
	if wire.IdempotencyKey != nil &&
		(len(*wire.IdempotencyKey) < 1 || len(*wire.IdempotencyKey) > 128) {
		return fmt.Errorf(
			"creation resolution idempotency_key must contain 1 to 128 characters",
		)
	}
	if wire.Generation != nil &&
		(len(*wire.Generation) < 1 || len(*wire.Generation) > 128) {
		return fmt.Errorf(
			"creation resolution generation must contain 1 to 128 characters",
		)
	}
	switch *wire.State {
	case CreationResolutionPending:
		if *wire.Recovery != CreationWait {
			return fmt.Errorf("pending creation resolution requires wait recovery")
		}
	case CreationResolutionCreated:
		if *wire.Recovery != CreationNoRecovery ||
			wire.CreatedPath == nil || wire.Generation == nil ||
			wire.Revision == nil {
			return fmt.Errorf(
				"created resolution requires none recovery, created_path, generation, and revision",
			)
		}
	case CreationResolutionNotApplied:
		if *wire.Recovery != CreationRetrySameIdempotencyKey &&
			*wire.Recovery != CreationRetryNewIdempotencyKey {
			return fmt.Errorf(
				"not_applied creation resolution requires a retry recovery",
			)
		}
	case CreationResolutionIndeterminate:
		if *wire.Recovery != CreationDoNotRetry {
			return fmt.Errorf(
				"indeterminate creation resolution requires do_not_retry recovery",
			)
		}
	default:
		return fmt.Errorf("unsupported creation resolution state %q", *wire.State)
	}
	*r = CreationResolution{
		CorrelationKey: *wire.CorrelationKey,
		State:          *wire.State,
		Recovery:       *wire.Recovery,
		Operation:      wire.Operation,
		IdempotencyKey: wire.IdempotencyKey,
		CreatedPath:    wire.CreatedPath,
		Generation:     wire.Generation,
		Revision:       wire.Revision,
	}
	return nil
}

type PingResult struct {
	Alive  bool   `json:"alive"`
	Cursor Cursor `json:"cursor"`
}

type ShutdownResult struct {
	Accepted bool `json:"accepted"`
}

type ReloadConfigResult struct {
	Reloaded bool     `json:"reloaded"`
	Warnings []string `json:"warnings"`
}

type TerminalDefaultsSnapshot struct {
	Foreground          *string           `json:"foreground,omitempty"`
	Background          *string           `json:"background,omitempty"`
	Cursor              *string           `json:"cursor,omitempty"`
	SelectionBackground *string           `json:"selection_background,omitempty"`
	SelectionForeground *string           `json:"selection_foreground,omitempty"`
	CursorStyle         *string           `json:"cursor_style,omitempty"`
	CursorBlink         *bool             `json:"cursor_blink,omitempty"`
	Palette             map[string]string `json:"palette,omitempty"`
}

type PairingResolutionResult struct {
	PairingRequest PairingRequestSnapshot `json:"pairing_request"`
}

type PaneNeighborResult struct {
	Pane *PaneSnapshot `json:"pane,omitempty"`
}

type TerminalScreenResult struct {
	Text          string               `json:"text"`
	Cols          uint16               `json:"cols"`
	Rows          uint16               `json:"rows"`
	CursorRow     uint16               `json:"cursor_row"`
	CursorColumn  uint16               `json:"cursor_col"`
	CursorVisible bool                 `json:"cursor_visible"`
	Extra         map[string]JSONValue `json:"extra,omitempty"`
}

type TerminalStateResult struct {
	State []byte `json:"state_base64"`
	Cols  uint16 `json:"cols"`
	Rows  uint16 `json:"rows"`
}

type TerminalHistoryResult struct {
	Start Decimal     `json:"start"`
	Next  *Decimal    `json:"next,omitempty"`
	Rows  []RenderRow `json:"rows"`
}

type TerminalWaitResult struct {
	Matched bool   `json:"matched"`
	Text    string `json:"text"`
}

type TerminalLifecycle string

const (
	TerminalLifecycleLaunching TerminalLifecycle = "launching"
	TerminalLifecycleRunning   TerminalLifecycle = "running"
	TerminalLifecycleExited    TerminalLifecycle = "exited"
)

type TerminalExitKind string

const (
	TerminalExitedNormally  TerminalExitKind = "exit"
	TerminalExitedBySignal  TerminalExitKind = "signal"
	TerminalExitKindUnknown TerminalExitKind = "unknown"
)

type TerminalExitOutcome interface {
	terminalExitOutcome()
}

type TerminalExitCode struct {
	Kind TerminalExitKind `json:"kind"`
	Code int32            `json:"code"`
}

type TerminalExitSignal struct {
	Kind       TerminalExitKind `json:"kind"`
	Signal     int32            `json:"signal"`
	CoreDumped bool             `json:"core_dumped"`
}

type TerminalExitUnknown struct {
	Kind   TerminalExitKind `json:"kind"`
	Reason string           `json:"reason"`
}

func (TerminalExitCode) terminalExitOutcome()    {}
func (TerminalExitSignal) terminalExitOutcome()  {}
func (TerminalExitUnknown) terminalExitOutcome() {}

type TerminalExit struct {
	Outcome  TerminalExitOutcome `json:"outcome"`
	ExitedAt Decimal             `json:"exited_at"`
	Revision Decimal             `json:"revision"`
}

func (e *TerminalExit) UnmarshalJSON(data []byte) error {
	var wire struct {
		Outcome  json.RawMessage `json:"outcome"`
		ExitedAt *Decimal        `json:"exited_at"`
		Revision *Decimal        `json:"revision"`
	}
	if err := strictDecode(data, &wire); err != nil {
		return err
	}
	if len(wire.Outcome) == 0 ||
		bytes.Equal(bytes.TrimSpace(wire.Outcome), []byte("null")) ||
		wire.ExitedAt == nil || wire.Revision == nil {
		return fmt.Errorf("terminal exit omitted a required field")
	}
	outcome, err := decodeTerminalExitOutcome(wire.Outcome)
	if err != nil {
		return err
	}
	*e = TerminalExit{
		Outcome: outcome, ExitedAt: *wire.ExitedAt, Revision: *wire.Revision,
	}
	return nil
}

type TerminalWaitExitState string

const (
	TerminalWaitExitStatePending TerminalWaitExitState = "pending"
	TerminalWaitExitStateExited  TerminalWaitExitState = "exited"
)

type TerminalWaitExitResult interface {
	terminalWaitExitResult()
}

type TerminalWaitExitPending struct {
	State      TerminalWaitExitState `json:"state"`
	TerminalID TerminalID            `json:"terminal_id"`
	Lifecycle  TerminalLifecycle     `json:"lifecycle"`
	Revision   Decimal               `json:"revision"`
}

type TerminalWaitExitExited struct {
	State      TerminalWaitExitState `json:"state"`
	TerminalID TerminalID            `json:"terminal_id"`
	Lifecycle  TerminalLifecycle     `json:"lifecycle"`
	Outcome    TerminalExitOutcome   `json:"outcome"`
	ExitedAt   Decimal               `json:"exited_at"`
	Revision   Decimal               `json:"revision"`
}

func (TerminalWaitExitPending) terminalWaitExitResult() {}
func (TerminalWaitExitExited) terminalWaitExitResult()  {}

func decodeTerminalExitOutcome(data json.RawMessage) (TerminalExitOutcome, error) {
	var discriminator struct {
		Kind *TerminalExitKind `json:"kind"`
	}
	if err := json.Unmarshal(data, &discriminator); err != nil {
		return nil, err
	}
	if discriminator.Kind == nil {
		return nil, fmt.Errorf("terminal exit outcome requires kind")
	}
	switch *discriminator.Kind {
	case TerminalExitedNormally:
		var wire struct {
			Kind *TerminalExitKind `json:"kind"`
			Code *int32            `json:"code"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.Kind == nil || wire.Code == nil {
			return nil, fmt.Errorf("terminal exit outcome requires kind and code")
		}
		return TerminalExitCode{Kind: *wire.Kind, Code: *wire.Code}, nil
	case TerminalExitedBySignal:
		var wire struct {
			Kind       *TerminalExitKind `json:"kind"`
			Signal     *int32            `json:"signal"`
			CoreDumped *bool             `json:"core_dumped"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.Kind == nil || wire.Signal == nil || *wire.Signal < 1 ||
			wire.CoreDumped == nil {
			return nil, fmt.Errorf(
				"terminal signal outcome requires a positive signal and core_dumped",
			)
		}
		return TerminalExitSignal{
			Kind: *wire.Kind, Signal: *wire.Signal, CoreDumped: *wire.CoreDumped,
		}, nil
	case TerminalExitKindUnknown:
		var wire struct {
			Kind   *TerminalExitKind `json:"kind"`
			Reason *string           `json:"reason"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.Kind == nil || wire.Reason == nil || *wire.Reason == "" {
			return nil, fmt.Errorf(
				"unknown terminal exit outcome requires a non-empty reason",
			)
		}
		return TerminalExitUnknown{
			Kind: *wire.Kind, Reason: *wire.Reason,
		}, nil
	default:
		return nil, fmt.Errorf(
			"unsupported terminal exit outcome kind %q",
			*discriminator.Kind,
		)
	}
}

func decodeTerminalWaitExitResult(
	data json.RawMessage,
) (TerminalWaitExitResult, error) {
	var discriminator struct {
		State *TerminalWaitExitState `json:"state"`
	}
	if err := json.Unmarshal(data, &discriminator); err != nil {
		return nil, err
	}
	if discriminator.State == nil {
		return nil, fmt.Errorf("terminal wait exit result requires state")
	}
	switch *discriminator.State {
	case TerminalWaitExitStatePending:
		var wire struct {
			State      *TerminalWaitExitState `json:"state"`
			TerminalID *TerminalID            `json:"terminal_id"`
			Lifecycle  *TerminalLifecycle     `json:"lifecycle"`
			Revision   *Decimal               `json:"revision"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.State == nil || wire.TerminalID == nil ||
			wire.Lifecycle == nil || wire.Revision == nil {
			return nil, fmt.Errorf(
				"pending terminal wait exit result omitted a required field",
			)
		}
		if *wire.Lifecycle != TerminalLifecycleLaunching &&
			*wire.Lifecycle != TerminalLifecycleRunning {
			return nil, fmt.Errorf(
				"pending terminal wait exit result has invalid lifecycle %q",
				*wire.Lifecycle,
			)
		}
		return TerminalWaitExitPending{
			State: *wire.State, TerminalID: *wire.TerminalID,
			Lifecycle: *wire.Lifecycle, Revision: *wire.Revision,
		}, nil
	case TerminalWaitExitStateExited:
		var wire struct {
			State      *TerminalWaitExitState `json:"state"`
			TerminalID *TerminalID            `json:"terminal_id"`
			Lifecycle  *TerminalLifecycle     `json:"lifecycle"`
			Outcome    json.RawMessage        `json:"outcome"`
			ExitedAt   *Decimal               `json:"exited_at"`
			Revision   *Decimal               `json:"revision"`
		}
		if err := strictDecode(data, &wire); err != nil {
			return nil, err
		}
		if wire.State == nil || wire.TerminalID == nil ||
			wire.Lifecycle == nil || len(wire.Outcome) == 0 ||
			bytes.Equal(bytes.TrimSpace(wire.Outcome), []byte("null")) ||
			wire.ExitedAt == nil || wire.Revision == nil {
			return nil, fmt.Errorf(
				"exited terminal wait exit result omitted a required field",
			)
		}
		if *wire.Lifecycle != TerminalLifecycleExited {
			return nil, fmt.Errorf(
				"exited terminal wait exit result has invalid lifecycle %q",
				*wire.Lifecycle,
			)
		}
		outcome, err := decodeTerminalExitOutcome(wire.Outcome)
		if err != nil {
			return nil, err
		}
		return TerminalWaitExitExited{
			State: *wire.State, TerminalID: *wire.TerminalID,
			Lifecycle: *wire.Lifecycle, Outcome: outcome,
			ExitedAt: *wire.ExitedAt, Revision: *wire.Revision,
		}, nil
	default:
		return nil, fmt.Errorf(
			"unsupported terminal wait exit state %q",
			*discriminator.State,
		)
	}
}

type TerminalCopyMode string

const (
	TerminalCopyScreen     TerminalCopyMode = "screen"
	TerminalCopySelection  TerminalCopyMode = "selection"
	TerminalCopyScrollback TerminalCopyMode = "scrollback"
)

type TerminalCopyResult struct {
	Mode TerminalCopyMode `json:"mode"`
	Text string           `json:"text"`
}

type ProcessInfoResult struct {
	PID        uint32   `json:"pid"`
	Executable *string  `json:"executable,omitempty"`
	Argv       []string `json:"argv"`
	CWD        *string  `json:"cwd,omitempty"`
	Children   []uint32 `json:"children"`
}

type CellPixelsResult struct {
	WidthPX          uint32            `json:"width_px"`
	HeightPX         uint32            `json:"height_px"`
	ResizedTerminals []TerminalID      `json:"resized_terminals"`
	Failures         map[string]string `json:"failures"`
}

type ViewerResizeResult struct {
	Accepted bool                  `json:"accepted"`
	Size     Size                  `json:"size"`
	Outcome  ViewAttachmentOutcome `json:"outcome"`
}

type BrowserViewerResizeResult struct {
	Accepted bool                  `json:"accepted"`
	Size     PixelSize             `json:"size"`
	Outcome  ViewAttachmentOutcome `json:"outcome"`
}

type ViewAttachmentOutcome string

const (
	ViewAttachmentApplied    ViewAttachmentOutcome = "applied"
	ViewAttachmentPassive    ViewAttachmentOutcome = "passive"
	ViewAttachmentSuperseded ViewAttachmentOutcome = "superseded"
)

type ViewerReleaseResult struct {
	Outcome ViewAttachmentOutcome `json:"outcome"`
}

type Document map[string]JSONValue

type RenderCursorStyle string

const (
	RenderCursorBlock     RenderCursorStyle = "block"
	RenderCursorUnderline RenderCursorStyle = "underline"
	RenderCursorBar       RenderCursorStyle = "bar"
)

type RenderUnderline string

const (
	RenderUnderlineSingle RenderUnderline = "single"
	RenderUnderlineDouble RenderUnderline = "double"
	RenderUnderlineCurly  RenderUnderline = "curly"
	RenderUnderlineDotted RenderUnderline = "dotted"
	RenderUnderlineDashed RenderUnderline = "dashed"
)

type RenderCursor struct {
	X       uint16            `json:"x"`
	Y       uint16            `json:"y"`
	Style   RenderCursorStyle `json:"style"`
	Blink   bool              `json:"blink"`
	Visible bool              `json:"visible"`
	Color   *string           `json:"color"`
}

type RenderRun struct {
	Text       string           `json:"text"`
	Foreground *string          `json:"fg"`
	Background *string          `json:"bg"`
	Attributes uint32           `json:"attrs"`
	Underline  *RenderUnderline `json:"underline,omitempty"`
	WidthHint  *uint16          `json:"width_hint,omitempty"`
}

type RenderRow struct {
	Row  uint16      `json:"row"`
	Runs []RenderRun `json:"runs"`
}

type RenderSnapshot struct {
	Size           Size         `json:"size"`
	Cursor         RenderCursor `json:"cursor"`
	DefaultFG      string       `json:"default_fg"`
	DefaultBG      string       `json:"default_bg"`
	ScrollbackRows uint32       `json:"scrollback_rows"`
	Rows           []RenderRow  `json:"rows"`
}

type RenderPatch struct {
	Cursor         RenderCursor `json:"cursor"`
	FullReset      bool         `json:"full_reset"`
	Size           *Size        `json:"size,omitempty"`
	DefaultFG      *string      `json:"default_fg,omitempty"`
	DefaultBG      *string      `json:"default_bg,omitempty"`
	ScrollbackRows *uint32      `json:"scrollback_rows,omitempty"`
	Rows           []RenderRow  `json:"rows"`
}

type RenderScroll struct {
	Offset   Decimal `json:"offset"`
	AtBottom bool    `json:"at_bottom"`
}

// Secret is an explicitly revealable sensitive wire string. Formatting never
// exposes its value, while JSON encoding preserves the credential for the
// intended request.
type Secret struct {
	value string
}

func NewSecret(value string) Secret { return Secret{value: value} }

func (s Secret) Reveal() string { return s.value }

func (Secret) String() string { return "<redacted>" }

func (Secret) GoString() string { return "cmux.Secret(<redacted>)" }

func (s Secret) MarshalJSON() ([]byte, error) { return json.Marshal(s.value) }

func (s *Secret) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return fmt.Errorf("cmux secret must be a JSON string: %w", err)
	}
	s.value = value
	return nil
}

type RendererGrant struct {
	Endpoint   string
	TerminalID TerminalID
	Token      Secret
	Rights     []string
	TTLMS      uint32
}

type RendererGrantResult = RendererGrant

func (g RendererGrant) String() string {
	return fmt.Sprintf(
		"RendererGrant{Endpoint:%q TerminalID:%s Token:<redacted> Rights:%v TTLMS:%d}",
		g.Endpoint, g.TerminalID, g.Rights, g.TTLMS,
	)
}

func (g RendererGrant) GoString() string { return g.String() }

type SessionEvent struct {
	Kind             string
	Cursor           *Cursor
	ResetReason      *string
	Snapshot         *ResourceSnapshot
	PreviousRevision Decimal
	Revision         Decimal
	Changes          []ResourceChange
	Raw              Document
}

type JournalClass string

const (
	JournalClassState       JournalClass = "state"
	JournalClassObservation JournalClass = "observation"
	JournalClassEffect      JournalClass = "effect"
	JournalClassCheckpoint  JournalClass = "checkpoint"
)

type JournalReplayPolicy string

const (
	JournalReplayRequired JournalReplayPolicy = "required"
	JournalReplayAdvisory JournalReplayPolicy = "advisory"
	JournalReplayNever    JournalReplayPolicy = "never"
)

type JournalSensitivity string

const (
	JournalSensitivityPublic    JournalSensitivity = "public"
	JournalSensitivityMetadata  JournalSensitivity = "metadata"
	JournalSensitivitySensitive JournalSensitivity = "sensitive"
	JournalSensitivitySecret    JournalSensitivity = "secret"
)

type JournalProducer struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

type JournalAuthority struct {
	PrincipalID string `json:"principal_id"`
	LeaseID     string `json:"lease_id"`
	Generation  string `json:"generation"`
	Role        string `json:"role"`
}

type JournalSubject struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

type SessionJournalRecord struct {
	Sequence                 Decimal
	EventID                  string
	SchemaVersion            uint32
	Kind                     string
	Class                    JournalClass
	Replay                   JournalReplayPolicy
	OccurredAtMS             Decimal
	CommittedAtMS            Decimal
	Producer                 JournalProducer
	Authority                *JournalAuthority
	CausationID              *string
	CorrelationID            *string
	CausationDepth           uint16
	Subjects                 []JournalSubject
	Sensitivity              JournalSensitivity
	Payload                  JSONValue
	ResourceRevision         *Decimal
	PreviousResourceRevision *Decimal
}

type TerminalAttachmentItem struct {
	Kind           string
	TerminalID     TerminalID
	RenderSnapshot *RenderSnapshot
	RenderPatch    *RenderPatch
	Scroll         *RenderScroll
	Raw            Document
}

type BrowserAttachmentItem struct {
	Kind            string
	Browser         *BrowserSnapshot
	Size            *PixelSize
	URL             string
	Title           string
	Loading         bool
	MIMEType        string
	Frame           []byte
	WidthPX         uint32
	HeightPX        uint32
	PointerFrameSeq *Decimal
	Raw             Document
}

type SidebarViewItem struct {
	Kind           string
	SidebarView    *SidebarViewSnapshot
	SidebarViewID  SidebarViewID
	RenderSnapshot *RenderSnapshot
	RenderPatch    *RenderPatch
	Scroll         *RenderScroll
	Raw            Document
}

type CreatedPath struct {
	Kind      string      `json:"kind"`
	Workspace WorkspaceID `json:"workspace_id,omitempty"`
	Screen    ScreenID    `json:"screen_id,omitempty"`
	Pane      PaneID      `json:"pane_id,omitempty"`
	Tab       TabID       `json:"tab_id,omitempty"`
	Terminal  TerminalID  `json:"terminal_id,omitempty"`
	Browser   BrowserID   `json:"browser_id,omitempty"`
}

func (p *CreatedPath) UnmarshalJSON(data []byte) error {
	var discriminator struct {
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(data, &discriminator); err != nil {
		return err
	}
	switch discriminator.Kind {
	case "workspace":
		var value struct {
			Kind      string       `json:"kind"`
			Workspace *WorkspaceID `json:"workspace_id"`
		}
		if err := strictDecode(data, &value); err != nil {
			return err
		}
		if value.Workspace == nil {
			return fmt.Errorf("workspace created path requires workspace_id")
		}
		*p = CreatedPath{Kind: value.Kind, Workspace: *value.Workspace}
	case "terminal":
		var value struct {
			Kind      string       `json:"kind"`
			Workspace *WorkspaceID `json:"workspace_id"`
			Screen    *ScreenID    `json:"screen_id"`
			Pane      *PaneID      `json:"pane_id"`
			Tab       *TabID       `json:"tab_id"`
			Terminal  *TerminalID  `json:"terminal_id"`
		}
		if err := strictDecode(data, &value); err != nil {
			return err
		}
		if value.Workspace == nil || value.Screen == nil ||
			value.Pane == nil || value.Tab == nil || value.Terminal == nil {
			return fmt.Errorf("terminal created path requires every ancestor and terminal_id")
		}
		*p = CreatedPath{
			Kind: value.Kind, Workspace: *value.Workspace,
			Screen: *value.Screen, Pane: *value.Pane,
			Tab: *value.Tab, Terminal: *value.Terminal,
		}
	case "browser":
		var value struct {
			Kind      string       `json:"kind"`
			Workspace *WorkspaceID `json:"workspace_id"`
			Screen    *ScreenID    `json:"screen_id"`
			Pane      *PaneID      `json:"pane_id"`
			Tab       *TabID       `json:"tab_id"`
			Browser   *BrowserID   `json:"browser_id"`
		}
		if err := strictDecode(data, &value); err != nil {
			return err
		}
		if value.Workspace == nil || value.Screen == nil ||
			value.Pane == nil || value.Tab == nil || value.Browser == nil {
			return fmt.Errorf("browser created path requires every ancestor and browser_id")
		}
		*p = CreatedPath{
			Kind: value.Kind, Workspace: *value.Workspace,
			Screen: *value.Screen, Pane: *value.Pane,
			Tab: *value.Tab, Browser: *value.Browser,
		}
	default:
		return fmt.Errorf("created path has unsupported kind %q", discriminator.Kind)
	}
	return nil
}

func decodeJSONFields(raw json.RawMessage) (map[string]JSONValue, error) {
	var fields map[string]JSONValue
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&fields); err != nil {
		return nil, err
	}
	return fields, nil
}
