package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	terminalbot "github.com/manaflow-ai/cmux/cmux-tui/bindings/examples/go-terminal-bot"
)

func main() {
	os.Exit(run())
}

func run() int {
	var config terminalbot.Config
	var timeout time.Duration
	var historyRows uint64
	flag.StringVar(&config.SocketPath, "socket", "", "explicit cmux-tui Unix socket")
	flag.StringVar(&config.Session, "session", "main", "cmux-tui session name")
	flag.StringVar(&config.WorkspaceName, "workspace-name", "", "isolated workspace name")
	flag.StringVar(&config.TerminalName, "terminal-name", "", "terminal tab name")
	flag.StringVar(&config.Cwd, "cwd", "", "task working directory")
	flag.DurationVar(&timeout, "timeout", 2*time.Minute, "overall task timeout")
	flag.BoolVar(&config.KeepWorkspace, "keep-workspace", false, "leave the workspace open")
	flag.Uint64Var(
		&historyRows,
		"history-rows",
		2_000,
		"terminal history rows to capture",
	)
	flag.Parse()
	if historyRows > 65_535 {
		fmt.Fprintln(os.Stderr, "go-terminal-bot: history-rows exceeds 65535")
		return 2
	}
	config.Timeout = timeout
	config.HistoryRows = uint32(historyRows)
	config.Argv = flag.Args()
	config.Output = os.Stdout

	bot, err := terminalbot.New(config)
	if err != nil {
		fmt.Fprintln(os.Stderr, "go-terminal-bot:", err)
		return 2
	}
	ctx, cancel := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer cancel()

	result, err := bot.Run(ctx)
	fmt.Fprintf(
		os.Stderr,
		"\nworkspace=%s terminal=%s exit=%d\n",
		result.Workspace,
		result.Terminal,
		result.ExitCode,
	)
	for _, warning := range result.Warnings {
		fmt.Fprintln(os.Stderr, "warning:", warning)
	}
	if err == nil {
		return 0
	}
	var taskErr *terminalbot.TaskError
	if errors.As(err, &taskErr) {
		if taskErr.ExitCode > 0 && taskErr.ExitCode < 126 {
			return taskErr.ExitCode
		}
		return 1
	}
	fmt.Fprintln(os.Stderr, "go-terminal-bot:", err)
	return 2
}
