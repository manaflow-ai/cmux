package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	socket := socketFromEnv()
	if socket == "" {
		return fmt.Errorf("CMUX_TUI_SOCKET is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	client, err := cmux.NewClient(cmux.Options{
		SocketPath:            socket,
		Timeout:               5 * time.Second,
		AllowProtocolV6Attach: true,
	})
	if err != nil {
		return err
	}
	defer client.Close()

	marker := fmt.Sprintf("CMUX_GO_E2E_%d_%d", os.Getpid(), time.Now().UnixNano())
	later := marker + "_ATTACH"
	info, err := client.Identify(ctx)
	if err != nil {
		return err
	}
	if info.App != "cmux-tui" || info.Protocol < 5 || info.Protocol > 10 {
		return fmt.Errorf("unexpected identify result: %+v", info)
	}
	cols, rows := uint16(80), uint16(24)
	created, err := client.NewWorkspace(ctx, cmux.NewWorkspaceOptions{
		Name: cmux.Value(marker),
		Cols: cmux.Value(cols),
		Rows: cmux.Value(rows),
	})
	if err != nil {
		return err
	}
	text := fmt.Sprintf("printf '%s\\n'\r", marker)
	if err := client.Send(
		ctx,
		created.Surface,
		cmux.SendOptions{Text: cmux.Value(text)},
	); err != nil {
		return err
	}
	if err := waitForMarker(ctx, client, created.Surface, marker); err != nil {
		return err
	}
	screen, err := client.ReadScreen(ctx, created.Surface)
	if err != nil {
		return err
	}
	if !strings.Contains(screen.Text, marker) {
		return fmt.Errorf("marker missing from read-screen")
	}
	tree, err := client.ListWorkspaces(ctx)
	if err != nil {
		return err
	}
	workspace, ok := findWorkspaceForSurface(tree, created.Surface)
	if !ok {
		return fmt.Errorf("workspace not found")
	}
	pane, ok := findPaneForSurface(tree, created.Surface)
	if !ok {
		return fmt.Errorf("pane not found")
	}
	if _, err := client.Split(ctx, pane, cmux.SplitDirectionRight, cmux.SplitOptions{}); err != nil {
		return err
	}
	if err := client.SetRatio(ctx, pane, cmux.SplitDirectionRight, 0.5); err != nil {
		return err
	}
	if err := client.RenameSurface(ctx, created.Surface, marker+"-renamed"); err != nil {
		return err
	}
	events, err := client.Subscribe(ctx)
	if err != nil {
		return err
	}
	defer events.Close()
	if _, err := client.ResizeSurface(ctx, created.Surface, 100, 31); err != nil {
		return err
	}
	resized, err := nextResized(events, created.Surface, time.Second)
	if err != nil {
		return err
	}
	if resized.Cols != 100 || resized.Rows != 31 {
		return fmt.Errorf("bad resize event: %+v", resized)
	}
	if _, err := client.ResizeSurface(ctx, created.Surface, 100, 31); err != nil {
		return err
	}
	if _, err := nextResized(events, created.Surface, 500*time.Millisecond); !errors.Is(err, cmux.ErrTimeout) {
		return fmt.Errorf("same-size resize emitted event or failed oddly: %v", err)
	}

	attach, err := client.AttachSurfaceWithOptions(
		ctx,
		created.Surface,
		cmux.AttachSurfaceOptions{
			Cols: cmux.Value(cols),
			Rows: cmux.Value(rows),
		},
	)
	if err != nil {
		return err
	}
	defer attach.Close()
	first, err := attach.Recv(ctx)
	if err != nil {
		return err
	}
	if first.EventName() != "vt-state" {
		return fmt.Errorf("first attach event was %s", first.EventName())
	}
	if info.Protocol >= 10 {
		sizingClient, size, ok, err := findClientSurfaceSize(ctx, client, created.Surface)
		if err != nil {
			return err
		}
		if !ok || !size.SizeParticipating {
			return fmt.Errorf("protocol 10 surface sizing state missing: %+v", size)
		}
		if err := client.SetClientSizing(
			ctx,
			created.Surface,
			false,
			cmux.SetClientSizingOptions{Client: cmux.Value(sizingClient)},
		); err != nil {
			return err
		}
		_, size, ok, err = findClientSurfaceSize(ctx, client, created.Surface)
		if err != nil {
			return err
		}
		if !ok || size.SizeParticipating {
			return fmt.Errorf("surface sizing mutation was not reflected: %+v", size)
		}
		if err := client.SetClientSizing(
			ctx,
			created.Surface,
			true,
			cmux.SetClientSizingOptions{Client: cmux.Value(sizingClient)},
		); err != nil {
			return err
		}
	}
	outputText := fmt.Sprintf("printf '%s\\n'\r", later)
	if err := client.Send(
		ctx,
		created.Surface,
		cmux.SendOptions{Text: cmux.Value(outputText)},
	); err != nil {
		return err
	}
	if err := nextAttachOutput(attach, 3*time.Second); err != nil {
		return err
	}
	if _, err := client.CloseWorkspaceByID(ctx, workspace); err != nil {
		return err
	}
	afterClose, err := client.ListWorkspaces(ctx)
	if err != nil {
		return err
	}
	if _, ok := findWorkspaceForSurface(afterClose, created.Surface); ok {
		return fmt.Errorf("closed workspace still present")
	}
	_, err = client.ReadScreen(ctx, created.Surface)
	var commandErr *cmux.CommandError
	if !errors.As(err, &commandErr) || commandErr.Message == "" {
		return fmt.Errorf("closed surface error was not command error preserving message: %v", err)
	}
	return nil
}

func socketFromEnv() string {
	if socket := os.Getenv("CMUX_TUI_SOCKET"); socket != "" {
		return socket
	}
	return os.Getenv("CMUX_MUX_SOCKET")
}

func waitForMarker(ctx context.Context, client *cmux.Client, surface uint64, marker string) error {
	deadline := time.Now().Add(5 * time.Second)
	last := ""
	for time.Now().Before(deadline) {
		screen, err := client.ReadScreen(ctx, surface)
		if err != nil {
			return err
		}
		last = screen.Text
		if strings.Contains(last, marker) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("marker not found; last screen: %q", last)
}

func nextResized(events *cmux.Stream, surface uint64, timeout time.Duration) (cmux.SurfaceResizedEvent, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		event, err := events.Recv(ctx)
		if err != nil {
			return cmux.SurfaceResizedEvent{}, err
		}
		if resized, ok := event.(cmux.SurfaceResizedEvent); ok && resized.Surface == surface {
			return resized, nil
		}
	}
}

func nextAttachOutput(events *cmux.Stream, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		event, err := events.Recv(ctx)
		if err != nil {
			return err
		}
		if event.EventName() == "output" || event.EventName() == "resized" {
			return nil
		}
	}
}

func findWorkspaceForSurface(tree cmux.Tree, surface uint64) (uint64, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return workspace.ID, true
					}
				}
			}
		}
	}
	return 0, false
}

func findPaneForSurface(tree cmux.Tree, surface uint64) (uint64, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return live.ID, true
					}
				}
			}
		}
	}
	return 0, false
}

func findScreenForSurface(tree cmux.Tree, surface uint64) (cmux.Screen, bool) {
	for _, workspace := range tree.Workspaces {
		for _, screen := range workspace.Screens {
			for _, pane := range screen.Panes {
				live, ok := pane.AsLivePane()
				if !ok {
					continue
				}
				for _, tab := range live.Tabs {
					if tab.Surface == surface {
						return screen, true
					}
				}
			}
		}
	}
	return cmux.Screen{}, false
}

func findClientSurfaceSize(
	ctx context.Context,
	client *cmux.Client,
	surface uint64,
) (uint64, cmux.ClientSurfaceSize, bool, error) {
	clients, err := client.ListClients(ctx)
	if err != nil {
		return 0, cmux.ClientSurfaceSize{}, false, err
	}
	for _, info := range clients {
		for _, size := range info.Sizes {
			if size.Surface == surface {
				return info.Client, size, true, nil
			}
		}
	}
	return 0, cmux.ClientSurfaceSize{}, false, nil
}
