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

type MutationResult[T any] struct {
	Value      T
	Generation string
	Revision   Decimal
	Replayed   bool
}

type EmptyResult struct{}

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

type Document struct {
	Fields map[string]any
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

// ExternalMachineSpecifier is provider-owned connection material. Formatting
// never exposes the value, while Reveal is an explicit wire-boundary action.
type ExternalMachineSpecifier struct {
	value string
}

func NewExternalMachineSpecifier(value string) (ExternalMachineSpecifier, error) {
	if len(value) == 0 || len(value) > 512 {
		return ExternalMachineSpecifier{}, fmt.Errorf(
			"%w: external machine specifier must contain 1 to 512 UTF-8 bytes",
			ErrInvalidArgument,
		)
	}
	for _, character := range value {
		if character < 0x20 || character == 0x7f {
			return ExternalMachineSpecifier{}, fmt.Errorf(
				"%w: external machine specifier must not contain control characters",
				ErrInvalidArgument,
			)
		}
	}
	return ExternalMachineSpecifier{value: value}, nil
}

func MustExternalMachineSpecifier(value string) ExternalMachineSpecifier {
	result, err := NewExternalMachineSpecifier(value)
	if err != nil {
		panic(err)
	}
	return result
}

func (s ExternalMachineSpecifier) Reveal() string { return s.value }

func (ExternalMachineSpecifier) String() string { return "<redacted>" }

func (ExternalMachineSpecifier) GoString() string {
	return "cmux.ExternalMachineSpecifier(<redacted>)"
}

type RendererGrant struct {
	Endpoint   string
	TerminalID TerminalID
	Token      Secret
	Rights     []string
	TTLMS      uint32
}

func (g RendererGrant) String() string {
	return fmt.Sprintf(
		"RendererGrant{Endpoint:%q TerminalID:%s Token:<redacted> Rights:%v TTLMS:%d}",
		g.Endpoint, g.TerminalID, g.Rights, g.TTLMS,
	)
}

func (g RendererGrant) GoString() string { return g.String() }

type ProviderCredential struct {
	Name  string `json:"name"`
	Value Secret `json:"value"`
}

func (c ProviderCredential) String() string {
	return fmt.Sprintf("ProviderCredential{Name:%q Value:<redacted>}", c.Name)
}

func (c ProviderCredential) GoString() string { return c.String() }

type SessionEvent struct {
	Kind             string
	Cursor           *Cursor
	ResetReason      *string
	Snapshot         map[string]any
	PreviousRevision Decimal
	Revision         Decimal
	Changes          []map[string]any
	Raw              map[string]any
}

type TerminalAttachmentItem struct {
	Kind       string
	TerminalID TerminalID
	Render     map[string]any
	Scroll     map[string]any
	Raw        map[string]any
}

type BrowserAttachmentItem struct {
	Kind     string
	Browser  *BrowserSnapshot
	Size     *PixelSize
	URL      string
	Title    string
	Loading  bool
	MIMEType string
	Frame    []byte
	WidthPX  uint32
	HeightPX uint32
	Raw      map[string]any
}

type SidebarViewItem struct {
	Kind          string
	SidebarView   *SidebarViewSnapshot
	SidebarViewID SidebarViewID
	Render        map[string]any
	Scroll        map[string]any
	Raw           map[string]any
}

type ProviderNoticeItem struct {
	Kind     string
	Notice   *ProviderNotice
	Sequence Decimal
	Raw      map[string]any
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

func decodeJSONFields(raw json.RawMessage) (map[string]any, error) {
	var fields map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&fields); err != nil {
		return nil, err
	}
	return fields, nil
}
