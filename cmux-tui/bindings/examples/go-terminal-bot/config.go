package terminalbot

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"time"
)

const (
	defaultWorkspaceName = "Go terminal bot"
	defaultTerminalName  = "automation task"
)

var ErrNoCommand = errors.New("terminal-bot command is empty")

// Config controls one isolated terminal task.
type Config struct {
	SocketPath string
	Session    string

	WorkspaceName string
	TerminalName  string
	Argv          []string
	Cwd           string

	Timeout        time.Duration
	IOTimeout      time.Duration
	CleanupTimeout time.Duration
	HistoryRows    uint32
	KeepWorkspace  bool
	Output         io.Writer
}

// Bot runs terminal automation through public cmux resource handles.
type Bot struct {
	config Config
	runID  string
}

// New validates configuration and creates collision-resistant mutation keys.
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
	if config.Session == "" {
		config.Session = "main"
	}
	if config.Timeout < 0 {
		return nil, fmt.Errorf("Timeout must not be negative")
	}
	if config.IOTimeout == 0 {
		if config.Timeout > 0 {
			config.IOTimeout = config.Timeout + time.Second
			if config.IOTimeout <= config.Timeout {
				return nil, fmt.Errorf("Timeout is too large")
			}
		} else {
			config.IOTimeout = 15 * time.Second
		}
	}
	if config.IOTimeout < 0 {
		return nil, fmt.Errorf("IOTimeout must not be negative")
	}
	if config.Timeout > 0 && config.IOTimeout <= config.Timeout {
		return nil, fmt.Errorf("IOTimeout must exceed Timeout")
	}
	if config.CleanupTimeout == 0 {
		config.CleanupTimeout = 5 * time.Second
	}
	if config.CleanupTimeout < 0 {
		return nil, fmt.Errorf("CleanupTimeout must not be negative")
	}
	if config.HistoryRows == 0 {
		config.HistoryRows = 2_000
	}

	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, fmt.Errorf("generate mutation key nonce: %w", err)
	}
	return &Bot{
		config: config,
		runID:  hex.EncodeToString(nonce[:]),
	}, nil
}
