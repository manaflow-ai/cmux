package raw_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go/raw"
)

const (
	testWorkspaceKey = "11111111-2222-3333-4444-55555555555a"
	testWorkspaceID  = cmux.ID(42)
)

func TestPublicRenderPlainTextHelpers(t *testing.T) {
	rows := []cmux.RenderRow{
		{
			Row: 7,
			Runs: []cmux.RenderRun{
				{Attrs: 1, Text: "hello "},
				{Attrs: 2, Text: "世界"},
			},
		},
		{Row: 8, Runs: []cmux.RenderRun{{Text: "next"}}},
	}

	if got := cmux.RenderRunPlainText(rows[0].Runs[0]); got != "hello " {
		t.Fatalf("run text = %q", got)
	}
	if got := cmux.RenderRowPlainText(rows[0]); got != "hello 世界" {
		t.Fatalf("row text = %q", got)
	}
	if got := cmux.RenderRowsPlainText(rows); got != "hello 世界\nnext" {
		t.Fatalf("rows text = %q", got)
	}
}

func TestPublicReadScrollbackTailUsesTwoBoundedSnapshots(t *testing.T) {
	listener, socket := externalUnixListener(t)
	serverDone := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer conn.Close()

		identify, err := externalReadRequest(conn)
		if err != nil {
			serverDone <- err
			return
		}
		if identify["cmd"] != "identify" {
			serverDone <- fmt.Errorf("first command = %v, want identify", identify["cmd"])
			return
		}
		if err := externalWriteSuccess(
			conn,
			identify["id"],
			externalIdentifyResult(nil),
		); err != nil {
			serverDone <- err
			return
		}

		probe, err := externalReadRequest(conn)
		if err != nil {
			serverDone <- err
			return
		}
		if err := requireRequestFields(probe, map[string]any{
			"cmd":     "read-scrollback",
			"surface": "9",
			"start":   "0",
			"count":   "0",
		}); err != nil {
			serverDone <- err
			return
		}
		if err := externalWriteSuccess(conn, probe["id"], map[string]any{
			"epoch": 1,
			"rows":  []any{},
			"start": 0,
			"total": 10,
		}); err != nil {
			serverDone <- err
			return
		}

		page, err := externalReadRequest(conn)
		if err != nil {
			serverDone <- err
			return
		}
		if err := requireRequestFields(page, map[string]any{
			"cmd":     "read-scrollback",
			"surface": "9",
			"start":   "7",
			"count":   "3",
		}); err != nil {
			serverDone <- err
			return
		}
		serverDone <- externalWriteSuccess(conn, page["id"], map[string]any{
			"epoch": 1,
			"rows": []any{
				externalRenderRow(7, "eight"),
				externalRenderRow(8, "nine"),
				externalRenderRow(9, "ten"),
			},
			"start": 7,
			"total": 10,
		})
	}()

	client, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	result, err := client.ReadScrollbackTail(context.Background(), 9, 3)
	if err != nil {
		t.Fatal(err)
	}
	if result.Start != 7 || result.Total != 10 {
		t.Fatalf("tail range = start %d total %d", result.Start, result.Total)
	}
	if got := cmux.RenderRowsPlainText(result.Rows); got != "eight\nnine\nten" {
		t.Fatalf("tail text = %q", got)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestPublicReadScrollbackTailRejectsOversizeBeforeWireWrite(t *testing.T) {
	assertExternalNoWrite(t, func(client *cmux.Client) error {
		_, err := client.ReadScrollbackTail(
			context.Background(),
			9,
			cmux.MaxScrollbackPageRows+1,
		)
		if !errors.Is(err, cmux.ErrInvalidArgument) {
			return fmt.Errorf("error = %v, want ErrInvalidArgument", err)
		}
		return nil
	})
}

func TestPublicContextCancellationPreservesStandardIdentity(t *testing.T) {
	t.Run("already canceled writes nothing", func(t *testing.T) {
		assertExternalNoWrite(t, func(client *cmux.Client) error {
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			_, err := client.Identify(ctx)
			if !errors.Is(err, context.Canceled) {
				return fmt.Errorf("error = %v, want context.Canceled", err)
			}
			if !errors.Is(err, cmux.ErrTimeout) {
				return fmt.Errorf("error = %v, want ErrTimeout", err)
			}
			return nil
		})
	})

	t.Run("deadline while reading", func(t *testing.T) {
		listener, socket := externalUnixListener(t)
		serverDone := make(chan error, 1)
		go func() {
			conn, err := listener.Accept()
			if err != nil {
				serverDone <- err
				return
			}
			defer conn.Close()
			if _, err := externalReadRequest(conn); err != nil {
				serverDone <- err
				return
			}
			_, err = io.Copy(io.Discard, conn)
			serverDone <- err
		}()

		client, err := cmux.NewClient(cmux.Options{
			SocketPath: socket,
			Timeout:    time.Second,
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
		defer cancel()
		_, err = client.Identify(ctx)
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("error = %v, want context.DeadlineExceeded", err)
		}
		if !errors.Is(err, cmux.ErrTimeout) {
			t.Fatalf("error = %v, want ErrTimeout", err)
		}
		if err := client.Close(); err != nil {
			t.Fatal(err)
		}
		if err := <-serverDone; err != nil {
			t.Fatal(err)
		}
	})
}

func TestProviderAuthorityDeniedBeforeWireWrite(t *testing.T) {
	t.Run("generated command", func(t *testing.T) {
		assertExternalNoWrite(t, func(client *cmux.Client) error {
			err := client.MarkWorkspacesProviderManaged(
				context.Background(),
				"provider-test",
			)
			if !errors.Is(err, cmux.ErrAuthority) {
				return fmt.Errorf("error = %v, want ErrAuthority", err)
			}
			var authorityError *cmux.AuthorityError
			if !errors.As(err, &authorityError) {
				return fmt.Errorf("error type = %T, want *AuthorityError", err)
			}
			if authorityError.Command != "mark-workspaces-provider-managed" ||
				authorityError.Required != cmux.AuthorityProviderAuthority {
				return fmt.Errorf("authority error = %#v", authorityError)
			}
			return nil
		})
	})

	t.Run("known raw command", func(t *testing.T) {
		assertExternalNoWrite(t, func(client *cmux.Client) error {
			_, err := client.SendRaw(context.Background(), map[string]any{
				"cmd":       "mark-workspaces-provider-managed",
				"authority": "provider-test",
			})
			if !errors.Is(err, cmux.ErrAuthority) {
				return fmt.Errorf("error = %v, want ErrAuthority", err)
			}
			return nil
		})
	})
}

func TestProviderAuthorityExplicitOptInWritesCommand(t *testing.T) {
	listener, socket := externalUnixListener(t)
	serverDone := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer conn.Close()
		identify, err := externalReadRequest(conn)
		if err != nil {
			serverDone <- err
			return
		}
		if err := externalWriteSuccess(conn, identify["id"], externalIdentifyResult(
			[]string{"provider-managed-workspace-authority-v2"},
		)); err != nil {
			serverDone <- err
			return
		}
		command, err := externalReadRequest(conn)
		if err != nil {
			serverDone <- err
			return
		}
		if command["cmd"] != "mark-workspaces-provider-managed" ||
			command["authority"] != "provider-test" {
			serverDone <- fmt.Errorf("provider request = %#v", command)
			return
		}
		serverDone <- externalWriteSuccess(
			conn,
			command["id"],
			map[string]any{},
		)
	}()

	client, err := cmux.NewClient(cmux.Options{
		SocketPath:              socket,
		Timeout:                 time.Second,
		EnableProviderAuthority: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.MarkWorkspacesProviderManaged(
		context.Background(),
		"provider-test",
	); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestGeneratedFieldCompatibilityRejectsActualCommandWrite(t *testing.T) {
	tests := []struct {
		name         string
		protocol     uint32
		capabilities []string
		feature      string
		call         func(context.Context, *cmux.Client) error
	}{
		{
			name:     "send paste",
			protocol: 6,
			feature:  "send.paste",
			call: func(ctx context.Context, client *cmux.Client) error {
				paste := true
				return client.Send(ctx, 9, cmux.SendOptions{Paste: &paste})
			},
		},
		{
			name:     "run workspace key",
			protocol: 8,
			feature:  "run.key",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.Run(
					ctx,
					cmux.RunOptions{Key: cmux.Value(testWorkspaceKey)},
				)
				return err
			},
		},
		{
			name:     "run workspace key explicit null",
			protocol: 8,
			feature:  "run.key",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.Run(
					ctx,
					cmux.RunOptions{Key: cmux.Null[string]()},
				)
				return err
			},
		},
		{
			name:     "default cursor color",
			protocol: 8,
			feature:  "set-default-colors.cursor",
			call: func(ctx context.Context, client *cmux.Client) error {
				return client.SetDefaultColors(
					ctx,
					cmux.SetDefaultColorsOptions{
						Cursor: cmux.Value(cmux.ColorHex("#ffffff")),
					},
				)
			},
		},
		{
			name:     "default cursor blink",
			protocol: 8,
			feature:  "set-default-colors.cursor_blink",
			call: func(ctx context.Context, client *cmux.Client) error {
				return client.SetDefaultColors(
					ctx,
					cmux.SetDefaultColorsOptions{
						CursorBlink: cmux.Value(true),
					},
				)
			},
		},
		{
			name:     "default cursor style",
			protocol: 8,
			feature:  "set-default-colors.cursor_style",
			call: func(ctx context.Context, client *cmux.Client) error {
				return client.SetDefaultColors(
					ctx,
					cmux.SetDefaultColorsOptions{
						CursorStyle: cmux.Value(cmux.CursorStyleBar),
					},
				)
			},
		},
		{
			name:     "subscribe surface filter",
			protocol: cmux.MuxProtocolVersion,
			feature:  "subscribe.surface",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.SubscribeWithOptions(
					ctx,
					cmux.SubscribeOptions{Surface: cmux.Value(cmux.ID(9))},
				)
				return err
			},
		},
		{
			name:     "subscribe surface filter explicit null",
			protocol: cmux.MuxProtocolVersion,
			feature:  "subscribe.surface",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.SubscribeWithOptions(
					ctx,
					cmux.SubscribeOptions{Surface: cmux.Null[cmux.ID]()},
				)
				return err
			},
		},
		{
			name:     "subscribe tree mode explicit null",
			protocol: 6,
			feature:  "subscribe.tree_events",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.SubscribeWithOptions(
					ctx,
					cmux.SubscribeOptions{
						TreeEvents: cmux.Null[cmux.TreeEventMode](),
					},
				)
				return err
			},
		},
		{
			name:     "attach initial size",
			protocol: cmux.MuxProtocolVersion,
			feature:  "attach-surface.cols",
			call: func(ctx context.Context, client *cmux.Client) error {
				cols := uint16(80)
				rows := uint16(24)
				_, err := client.AttachSurfaceWithOptions(
					ctx,
					9,
					cmux.AttachSurfaceOptions{
						Cols: cmux.Value(cols),
						Rows: cmux.Value(rows),
					},
				)
				return err
			},
		},
		{
			name:     "attach initial size explicit null",
			protocol: cmux.MuxProtocolVersion,
			feature:  "attach-surface.cols",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.AttachSurfaceWithOptions(
					ctx,
					9,
					cmux.AttachSurfaceOptions{
						Cols: cmux.Null[uint16](),
						Rows: cmux.Null[uint16](),
					},
				)
				return err
			},
		},
		{
			name:     "workspace registry key",
			protocol: 7,
			feature:  "close-workspace.key",
			call: func(ctx context.Context, client *cmux.Client) error {
				_, err := client.CloseWorkspace(
					ctx,
					cmux.CloseWorkspaceOptions{
						Key: cmux.Value(testWorkspaceKey),
					},
				)
				return err
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			listener, socket := externalUnixListener(t)
			serverDone := make(chan error, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					serverDone <- err
					return
				}
				defer conn.Close()
				identify, err := externalReadRequest(conn)
				if err != nil {
					serverDone <- err
					return
				}
				if identify["cmd"] != "identify" {
					serverDone <- fmt.Errorf(
						"first command = %v, want identify",
						identify["cmd"],
					)
					return
				}
				data := externalIdentifyResult(test.capabilities)
				data["protocol"] = test.protocol
				if err := externalWriteSuccess(conn, identify["id"], data); err != nil {
					serverDone <- err
					return
				}
				if err := conn.SetReadDeadline(
					time.Now().Add(120 * time.Millisecond),
				); err != nil {
					serverDone <- err
					return
				}
				buffer := make([]byte, 1)
				n, readErr := conn.Read(buffer)
				if n != 0 {
					serverDone <- fmt.Errorf(
						"unsupported field wrote command byte %q",
						buffer[:n],
					)
					return
				}
				var netError net.Error
				if !errors.As(readErr, &netError) || !netError.Timeout() {
					serverDone <- fmt.Errorf("no-write read error = %v", readErr)
					return
				}
				serverDone <- nil
			}()

			client, err := cmux.NewClient(cmux.Options{
				SocketPath: socket,
				Timeout:    300 * time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			err = test.call(context.Background(), client)
			if !errors.Is(err, cmux.ErrProtocolMismatch) {
				t.Fatalf("error = %v, want ErrProtocolMismatch", err)
			}
			if !strings.Contains(err.Error(), test.feature) {
				t.Fatalf("error = %q, want feature %q", err, test.feature)
			}
			if err := <-serverDone; err != nil {
				t.Fatal(err)
			}

			unixListener, ok := listener.(*net.UnixListener)
			if !ok {
				t.Fatalf("listener type = %T", listener)
			}
			if err := unixListener.SetDeadline(
				time.Now().Add(40 * time.Millisecond),
			); err != nil {
				t.Fatal(err)
			}
			unexpected, acceptErr := listener.Accept()
			if acceptErr == nil {
				_ = unexpected.Close()
				t.Fatal("unsupported stream field opened a command connection")
			}
			var netError net.Error
			if !errors.As(acceptErr, &netError) || !netError.Timeout() {
				t.Fatalf("second accept error = %v", acceptErr)
			}
		})
	}
}

func TestUnsetRequiredNullableRequestWritesNothing(t *testing.T) {
	assertExternalNoWrite(t, func(client *cmux.Client) error {
		_, err := client.PutFrontendProjection(
			context.Background(),
			cmux.PutFrontendProjectionRequest{
				Frontend:      "test",
				Scope:         "workspace",
				SubjectKey:    testWorkspaceKey,
				SchemaVersion: 1,
			},
		)
		if !errors.Is(err, cmux.ErrInvalidArgument) {
			t.Fatalf("error = %v, want ErrInvalidArgument", err)
		}
		return nil
	})
}

func TestPublicCommandMetadataFieldMapsAreDefensiveCopies(t *testing.T) {
	metadata, ok := cmux.CommandInfo("send")
	if !ok || metadata.FieldSince["paste"] != 7 {
		t.Fatalf("send metadata = %#v, %v", metadata, ok)
	}
	metadata.FieldSince["paste"] = 99
	again, ok := cmux.CommandInfo("send")
	if !ok || again.FieldSince["paste"] != 7 {
		t.Fatalf("mutated shared command metadata: %#v", again)
	}

	all := cmux.AllCommandMetadata()
	for index := range all {
		if all[index].Name == "send" {
			all[index].FieldSince["paste"] = 88
		}
	}
	again, _ = cmux.CommandInfo("send")
	if again.FieldSince["paste"] != 7 {
		t.Fatalf("AllCommandMetadata exposed shared map: %#v", again)
	}
}

func TestWorkspaceLeaseDiscoversCreatesAndClosesOnce(t *testing.T) {
	listener, socket := externalUnixListener(t)
	serverDone := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer conn.Close()
		revision := uint64(1)
		live := false
		createCount := 0
		closeCount := 0
		for {
			request, err := externalReadRequest(conn)
			if err != nil {
				serverDone <- err
				return
			}
			switch request["cmd"] {
			case "identify":
				err = externalWriteSuccess(
					conn,
					request["id"],
					externalIdentifyResult([]string{"workspace-registry-v1"}),
				)
			case "list-workspaces":
				err = externalWriteSuccess(
					conn,
					request["id"],
					externalWorkspaceTree(live, revision),
				)
			case "create-workspace":
				createCount++
				if request["key"] != testWorkspaceKey ||
					request["origin"] != "go-test" ||
					request["mutation_id"] != "create-1" ||
					request["name"] != "leased" {
					serverDone <- fmt.Errorf("create request = %#v", request)
					return
				}
				live = true
				revision++
				err = externalWriteSuccess(
					conn,
					request["id"],
					externalWorkspaceMutation(revision, false),
				)
			case "close-workspace":
				closeCount++
				if request["key"] != testWorkspaceKey ||
					request["origin"] != "go-test" ||
					request["mutation_id"] != "close-1" ||
					externalNumber(request["workspace"]) != uint64(testWorkspaceID) {
					serverDone <- fmt.Errorf("close request = %#v", request)
					return
				}
				live = false
				revision++
				if err := externalWriteSuccess(
					conn,
					request["id"],
					externalWorkspaceMutation(revision, false),
				); err != nil {
					serverDone <- err
					return
				}
				if createCount != 1 || closeCount != 1 {
					serverDone <- fmt.Errorf(
						"create count %d, close count %d",
						createCount,
						closeCount,
					)
					return
				}
				if err := conn.SetReadDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
					serverDone <- err
					return
				}
				buffer := make([]byte, 1)
				n, readErr := conn.Read(buffer)
				if n != 0 {
					serverDone <- fmt.Errorf("idempotent close wrote %q", buffer[:n])
					return
				}
				var netError net.Error
				if !errors.As(readErr, &netError) || !netError.Timeout() {
					serverDone <- fmt.Errorf("no-write read error = %v", readErr)
					return
				}
				serverDone <- nil
				return
			default:
				serverDone <- fmt.Errorf("unexpected command %v", request["cmd"])
				return
			}
			if err != nil {
				serverDone <- err
				return
			}
		}
	}()

	client, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	name := "leased"
	options := cmux.WorkspaceLeaseOptions{
		Key:              testWorkspaceKey,
		Name:             &name,
		Origin:           "go-test",
		CreateMutationID: "create-1",
		CloseMutationID:  "close-1",
	}
	lease, err := client.DiscoverOrCreateWorkspace(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if lease.Workspace() != testWorkspaceID || lease.Key() != testWorkspaceKey ||
		!lease.Created() || lease.Replayed() || lease.Closed() {
		t.Fatalf("created lease has unexpected state")
	}

	discovered, err := client.DiscoverOrCreateWorkspace(
		context.Background(),
		options,
	)
	if err != nil {
		t.Fatal(err)
	}
	if discovered.Workspace() != testWorkspaceID ||
		discovered.Created() || discovered.Replayed() {
		t.Fatalf("discovered lease has unexpected state")
	}

	if err := lease.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !lease.Closed() {
		t.Fatal("lease did not record successful close")
	}
	if err := lease.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceLeaseRetryAcrossReplacementClient(t *testing.T) {
	listener, socket := externalUnixListener(t)
	serverDone := make(chan error, 1)
	go func() {
		first, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		if err := serveDroppedLeaseClose(first); err != nil {
			_ = first.Close()
			serverDone <- err
			return
		}
		_ = first.Close()

		replacement, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer replacement.Close()
		request, err := externalReadRequest(replacement)
		if err != nil {
			serverDone <- err
			return
		}
		if request["cmd"] != "list-workspaces" {
			serverDone <- fmt.Errorf("replacement command = %v", request["cmd"])
			return
		}
		serverDone <- externalWriteSuccess(
			replacement,
			request["id"],
			externalWorkspaceTree(false, 3),
		)
	}()

	first, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	options := cmux.WorkspaceLeaseOptions{
		Key:              testWorkspaceKey,
		Origin:           "go-test",
		CreateMutationID: "create-retry",
		CloseMutationID:  "close-retry",
	}
	lease, err := first.DiscoverOrCreateWorkspace(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.Close(context.Background()); !errors.Is(err, cmux.ErrConnection) {
		t.Fatalf("lost close response error = %v, want ErrConnection", err)
	}
	if lease.Closed() {
		t.Fatal("failed close must remain retryable")
	}
	_ = first.Close()

	replacement, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	if err := lease.CloseWith(context.Background(), replacement); err != nil {
		t.Fatal(err)
	}
	if !lease.Closed() {
		t.Fatal("replacement client did not reconcile committed close")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceLeaseDiscoversAfterLostCreateResponse(t *testing.T) {
	listener, socket := externalUnixListener(t)
	serverDone := make(chan error, 1)
	go func() {
		first, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		list, err := externalReadRequest(first)
		if err != nil || list["cmd"] != "list-workspaces" {
			_ = first.Close()
			serverDone <- fmt.Errorf("first list request = %#v, %v", list, err)
			return
		}
		if err := externalWriteSuccess(
			first,
			list["id"],
			externalWorkspaceTree(false, 1),
		); err != nil {
			_ = first.Close()
			serverDone <- err
			return
		}
		identify, err := externalReadRequest(first)
		if err != nil || identify["cmd"] != "identify" {
			_ = first.Close()
			serverDone <- fmt.Errorf("identify request = %#v, %v", identify, err)
			return
		}
		if err := externalWriteSuccess(
			first,
			identify["id"],
			externalIdentifyResult([]string{"workspace-registry-v1"}),
		); err != nil {
			_ = first.Close()
			serverDone <- err
			return
		}
		create, err := externalReadRequest(first)
		if err != nil || create["cmd"] != "create-workspace" {
			_ = first.Close()
			serverDone <- fmt.Errorf("create request = %#v, %v", create, err)
			return
		}
		_ = first.Close()

		replacement, err := listener.Accept()
		if err != nil {
			serverDone <- err
			return
		}
		defer replacement.Close()
		list, err = externalReadRequest(replacement)
		if err != nil || list["cmd"] != "list-workspaces" {
			serverDone <- fmt.Errorf("replacement list request = %#v, %v", list, err)
			return
		}
		serverDone <- externalWriteSuccess(
			replacement,
			list["id"],
			externalWorkspaceTree(true, 2),
		)
	}()

	options := cmux.WorkspaceLeaseOptions{
		Key:              testWorkspaceKey,
		Origin:           "go-test",
		CreateMutationID: "create-lost",
		CloseMutationID:  "close-lost",
	}
	first, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := first.DiscoverOrCreateWorkspace(
		context.Background(),
		options,
	); !errors.Is(err, cmux.ErrConnection) {
		t.Fatalf("lost create response error = %v, want ErrConnection", err)
	}
	_ = first.Close()

	replacement, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	lease, err := replacement.DiscoverOrCreateWorkspace(
		context.Background(),
		options,
	)
	if err != nil {
		t.Fatal(err)
	}
	if lease.Workspace() != testWorkspaceID || lease.Created() || lease.Replayed() {
		t.Fatal("replacement client did not discover the committed workspace")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceLeaseValidationWritesNothing(t *testing.T) {
	for name, options := range map[string]cmux.WorkspaceLeaseOptions{
		"uppercase key": {
			Key:              strings.ToUpper(testWorkspaceKey),
			Origin:           "go-test",
			CreateMutationID: "create",
			CloseMutationID:  "close",
		},
		"same mutation": {
			Key:              testWorkspaceKey,
			Origin:           "go-test",
			CreateMutationID: "same",
			CloseMutationID:  "same",
		},
		"empty origin": {
			Key:              testWorkspaceKey,
			CreateMutationID: "create",
			CloseMutationID:  "close",
		},
	} {
		t.Run(name, func(t *testing.T) {
			assertExternalNoWrite(t, func(client *cmux.Client) error {
				_, err := client.DiscoverOrCreateWorkspace(
					context.Background(),
					options,
				)
				if !errors.Is(err, cmux.ErrInvalidArgument) {
					return fmt.Errorf("error = %v, want ErrInvalidArgument", err)
				}
				return nil
			})
		})
	}
}

func serveDroppedLeaseClose(conn net.Conn) error {
	defer conn.SetDeadline(time.Time{})
	revision := uint64(1)
	live := false
	for {
		request, err := externalReadRequest(conn)
		if err != nil {
			return err
		}
		switch request["cmd"] {
		case "identify":
			if err := externalWriteSuccess(
				conn,
				request["id"],
				externalIdentifyResult([]string{"workspace-registry-v1"}),
			); err != nil {
				return err
			}
		case "list-workspaces":
			if err := externalWriteSuccess(
				conn,
				request["id"],
				externalWorkspaceTree(live, revision),
			); err != nil {
				return err
			}
		case "create-workspace":
			live = true
			revision++
			if err := externalWriteSuccess(
				conn,
				request["id"],
				externalWorkspaceMutation(revision, false),
			); err != nil {
				return err
			}
		case "close-workspace":
			return nil
		default:
			return fmt.Errorf("unexpected command %v", request["cmd"])
		}
	}
}

func assertExternalNoWrite(
	t *testing.T,
	action func(client *cmux.Client) error,
) {
	t.Helper()
	listener, socket := externalUnixListener(t)
	accepted := make(chan net.Conn, 1)
	acceptError := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			acceptError <- err
			return
		}
		accepted <- conn
	}()

	client, err := cmux.NewClient(cmux.Options{
		SocketPath: socket,
		Timeout:    time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	var conn net.Conn
	select {
	case conn = <-accepted:
	case err := <-acceptError:
		t.Fatal(err)
	case <-time.After(time.Second):
		t.Fatal("server did not accept client")
	}
	defer conn.Close()

	readDone := make(chan error, 1)
	go func() {
		if err := conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
			readDone <- err
			return
		}
		buffer := make([]byte, 1)
		n, err := conn.Read(buffer)
		if n != 0 {
			readDone <- fmt.Errorf("unexpected wire byte %q", buffer[:n])
			return
		}
		var netError net.Error
		if !errors.As(err, &netError) || !netError.Timeout() {
			readDone <- fmt.Errorf("no-write read error = %v", err)
			return
		}
		readDone <- nil
	}()

	if err := action(client); err != nil {
		t.Fatal(err)
	}
	if err := <-readDone; err != nil {
		t.Fatal(err)
	}
}

func externalUnixListener(t *testing.T) (net.Listener, string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "cmux-go-external-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(directory)
	})
	socket := filepath.Join(directory, "cmux.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
	})
	return listener, socket
}

func externalReadRequest(conn net.Conn) (map[string]any, error) {
	var request map[string]any
	decoder := json.NewDecoder(conn)
	decoder.UseNumber()
	if err := decoder.Decode(&request); err != nil {
		return nil, err
	}
	return request, nil
}

func externalWriteSuccess(conn net.Conn, id any, data any) error {
	return json.NewEncoder(conn).Encode(map[string]any{
		"id":   id,
		"ok":   true,
		"data": data,
	})
}

func externalIdentifyResult(capabilities []string) map[string]any {
	result := map[string]any{
		"app":                "cmux-tui",
		"version":            "test",
		"protocol":           cmux.MuxProtocolVersion,
		"session":            "go-test",
		"pid":                1,
		"registry_id":        "registry-1",
		"generation":         "generation-1",
		"workspace_revision": 1,
		"terminal_revision":  1,
		"daemon_handoff":     1,
	}
	if capabilities != nil {
		result["capabilities"] = capabilities
	}
	return result
}

func externalRenderRow(row uint32, text string) map[string]any {
	return map[string]any{
		"row": row,
		"runs": []any{map[string]any{
			"attrs": 0,
			"bg":    nil,
			"fg":    nil,
			"text":  text,
		}},
	}
}

func externalWorkspaceTree(live bool, revision uint64) map[string]any {
	workspaces := []any{}
	if live {
		workspaces = append(workspaces, map[string]any{
			"active":  false,
			"id":      testWorkspaceID,
			"key":     testWorkspaceKey,
			"name":    "leased",
			"screens": []any{},
		})
	}
	return map[string]any{
		"generation":         "generation-1",
		"registry_id":        "registry-1",
		"workspace_revision": revision,
		"workspaces":         workspaces,
	}
}

func externalWorkspaceMutation(
	revision uint64,
	replayed bool,
) map[string]any {
	changed := true
	return map[string]any{
		"changed":            changed,
		"generation":         "generation-1",
		"index":              0,
		"key":                testWorkspaceKey,
		"registry_id":        "registry-1",
		"replayed":           replayed,
		"workspace":          testWorkspaceID,
		"workspace_revision": revision,
	}
}

func requireRequestFields(request map[string]any, expected map[string]any) error {
	for key, want := range expected {
		got := request[key]
		if number, ok := got.(json.Number); ok {
			got = number.String()
		}
		if got != want {
			return fmt.Errorf("%s = %v, want %v in %#v", key, got, want, request)
		}
	}
	return nil
}

func externalNumber(value any) uint64 {
	number, _ := value.(json.Number).Int64()
	return uint64(number)
}
