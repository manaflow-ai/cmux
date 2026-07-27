package terminalbot

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

const (
	defaultWorkspaceName = "Go terminal bot"
	defaultTerminalName  = "automation task"
	defaultAgentSession  = "go-terminal-bot"
	defaultShell         = "/bin/sh"
)

var ErrNoCommand = errors.New("terminal-bot command is empty")

// Observer receives serialized task activity while Run is active.
type Observer interface {
	Output([]byte)
	Event(cmux.Event)
	Reconnect(scope string, attempt int, err error)
}

// Config controls one isolated terminal task.
type Config struct {
	SocketPath string
	Session    string

	WorkspaceKey  string
	WorkspaceName string
	TerminalID    string
	TerminalName  string
	AgentSession  string
	MutationID    string

	Argv []string
	Cwd  string

	Timeout        time.Duration
	IOTimeout      time.Duration
	CleanupTimeout time.Duration
	RetryLimit     int
	RetryDelay     time.Duration
	ExitGrace      time.Duration

	ScrollbackRows uint32
	MaxOutputBytes int
	KeepWorkspace  bool

	Output   io.Writer
	Observer Observer
}

// Bot runs terminal automation through the public cmux Go SDK.
type Bot struct {
	config Config
}

// New validates config and fills per-run identifiers.
func New(config Config) (*Bot, error) {
	if len(config.Argv) == 0 {
		return nil, ErrNoCommand
	}
	if config.WorkspaceName == "" {
		config.WorkspaceName = defaultWorkspaceName
	}
	if config.TerminalName == "" {
		config.TerminalName = defaultTerminalName
	}
	if config.AgentSession == "" {
		config.AgentSession = defaultAgentSession
	}
	if config.Session == "" {
		config.Session = "main"
	}
	if config.Timeout < 0 {
		return nil, fmt.Errorf("Timeout must not be negative")
	}
	if config.IOTimeout == 0 {
		config.IOTimeout = 15 * time.Second
	}
	if config.IOTimeout < 0 {
		return nil, fmt.Errorf("IOTimeout must not be negative")
	}
	if config.CleanupTimeout == 0 {
		config.CleanupTimeout = 5 * time.Second
	}
	if config.CleanupTimeout < 0 {
		return nil, fmt.Errorf("CleanupTimeout must not be negative")
	}
	if config.RetryLimit == 0 {
		config.RetryLimit = 3
	}
	if config.RetryLimit < 0 {
		return nil, fmt.Errorf("RetryLimit must not be negative")
	}
	if config.RetryDelay == 0 {
		config.RetryDelay = 100 * time.Millisecond
	}
	if config.RetryDelay < 0 {
		return nil, fmt.Errorf("RetryDelay must not be negative")
	}
	if config.ExitGrace == 0 {
		config.ExitGrace = 2 * time.Second
	}
	if config.ExitGrace < 0 {
		return nil, fmt.Errorf("ExitGrace must not be negative")
	}
	if config.ScrollbackRows == 0 {
		config.ScrollbackRows = 2_000
	}
	if config.ScrollbackRows > 65_535 {
		return nil, fmt.Errorf("ScrollbackRows exceeds protocol maximum 65535")
	}
	if config.MaxOutputBytes == 0 {
		config.MaxOutputBytes = 1 << 20
	}
	if config.MaxOutputBytes < 0 {
		return nil, fmt.Errorf("MaxOutputBytes must not be negative")
	}

	var err error
	if config.WorkspaceKey == "" {
		config.WorkspaceKey, err = randomUUID()
		if err != nil {
			return nil, err
		}
	}
	if config.TerminalID == "" {
		config.TerminalID, err = randomUUID()
		if err != nil {
			return nil, err
		}
	}
	if config.MutationID == "" {
		config.MutationID, err = randomUUID()
		if err != nil {
			return nil, err
		}
	}

	return &Bot{config: config}, nil
}

func randomUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate UUID: %w", err)
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%08x-%04x-%04x-%04x-%012x",
		value[0:4],
		value[4:6],
		value[6:8],
		value[8:10],
		value[10:16],
	), nil
}
