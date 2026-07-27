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
	var scrollbackRows uint64
	flag.StringVar(&config.SocketPath, "socket", "", "explicit cmux-tui Unix socket")
	flag.StringVar(&config.Session, "session", "main", "cmux-tui session name")
	flag.StringVar(&config.WorkspaceKey, "workspace-key", "", "bot-owned workspace UUID")
	flag.StringVar(&config.WorkspaceName, "workspace-name", "", "isolated workspace name")
	flag.StringVar(&config.TerminalName, "terminal-name", "", "terminal tab name")
	flag.StringVar(&config.Cwd, "cwd", "", "task working directory")
	flag.DurationVar(&timeout, "timeout", 2*time.Minute, "overall task timeout")
	flag.IntVar(&config.RetryLimit, "retries", 3, "stream reconnect attempts")
	flag.BoolVar(&config.KeepWorkspace, "keep-workspace", false, "leave the workspace open")
	flag.Uint64Var(
		&scrollbackRows,
		"scrollback-rows",
		2_000,
		"scrollback rows to retain",
	)
	flag.Parse()
	if scrollbackRows > 65_535 {
		fmt.Fprintln(os.Stderr, "go-terminal-bot: scrollback-rows exceeds 65535")
		return 2
	}
	config.Timeout = timeout
	config.ScrollbackRows = uint32(scrollbackRows)
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
		"\nworkspace=%d surface=%d terminal=%s exit=%d reconnects=%d\n",
		result.Workspace,
		result.Surface,
		result.TerminalID,
		result.ExitCode,
		result.Reconnects,
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
