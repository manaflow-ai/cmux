package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

type constants struct {
	Machine        string `json:"machine"`
	Session        string `json:"session"`
	Workspace      string `json:"workspace"`
	Generation     string `json:"generation"`
	Revision       string `json:"revision"`
	IdempotencyKey string `json:"idempotency_key"`
	Name           string `json:"name"`
}

type request struct {
	ContractVersion int       `json:"contract_version"`
	ID              string    `json:"id"`
	Op              string    `json:"op"`
	SocketPath      string    `json:"socket_path"`
	Dimension       string    `json:"dimension"`
	WorkspaceName   string    `json:"workspace_name"`
	Constants       constants `json:"constants"`
}

type response struct {
	ContractVersion int           `json:"contract_version"`
	ID              string        `json:"id"`
	OK              bool          `json:"ok"`
	Value           any           `json:"value,omitempty"`
	Error           *adapterError `json:"error,omitempty"`
}

type adapterError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

func main() {
	var input request
	if err := json.NewDecoder(bufio.NewReader(os.Stdin)).Decode(&input); err != nil {
		write(response{
			ContractVersion: 2,
			OK:              false,
			Error:           &adapterError{Kind: "adapter", Message: err.Error()},
		})
		return
	}
	value, err := dispatch(input)
	if err != nil {
		write(response{
			ContractVersion: 2,
			ID:              input.ID,
			OK:              false,
			Error:           &adapterError{Kind: classify(err), Message: err.Error()},
		})
		return
	}
	write(response{ContractVersion: 2, ID: input.ID, OK: true, Value: value})
}

func write(value response) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func classify(err error) string {
	var resource *cmux.ResourceError
	var protocol *cmux.ProtocolError
	var transport *cmux.TransportError
	switch {
	case errors.As(err, &resource):
		return "resource"
	case errors.As(err, &protocol):
		return "protocol"
	case errors.As(err, &transport):
		return "transport"
	default:
		return "adapter"
	}
}

func dispatch(input request) (any, error) {
	if input.Op == "redaction" {
		return redaction()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	client, err := cmux.NewClient(ctx, cmux.ClientOptions{
		SocketPath: input.SocketPath,
		Timeout:    15 * time.Second,
	})
	if err != nil {
		return nil, err
	}
	defer client.Close(context.Background()) //nolint:errcheck
	session, workspace, err := handles(client, input.Constants)
	if err != nil {
		return nil, err
	}

	switch input.Op {
	case "read":
		document, err := session.Ping(ctx, cmux.SessionPingOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"alive":  document.Fields["alive"],
			"cursor": normalize(document.Fields["cursor"]),
		}, nil
	case "mutation-replay":
		options, err := renameOptions(input.Constants)
		if err != nil {
			return nil, err
		}
		first, err := workspace.Rename(ctx, options)
		if err != nil {
			return nil, err
		}
		second, err := workspace.Rename(ctx, options)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"first":  mutationValue(first),
			"second": mutationValue(second),
		}, nil
	case "mutation-error":
		options, err := renameOptions(input.Constants)
		if err != nil {
			return nil, err
		}
		_, err = workspace.Rename(ctx, options)
		if err == nil {
			return nil, errors.New("mutation unexpectedly succeeded")
		}
		var resource *cmux.ResourceError
		if !errors.As(err, &resource) {
			return nil, err
		}
		var details any
		decoder := json.NewDecoder(strings.NewReader(string(resource.Details)))
		decoder.UseNumber()
		if err := decoder.Decode(&details); err != nil {
			return nil, err
		}
		return map[string]any{
			"code":      resource.Code,
			"message":   resource.Message,
			"details":   normalize(details),
			"retryable": resource.Retryable,
		}, nil
	case "stream-unknown":
		stream, err := session.Events(ctx, cmux.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		item, err := stream.Recv(ctx)
		if err != nil {
			return nil, err
		}
		end, err := receiveEnd(ctx, stream)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"sequence": item.Sequence.String(),
			"cursor":   cursorValue(item.Cursor),
			"kind":     item.Value.Kind,
			"raw":      normalize(item.Value.Raw),
			"end":      end,
		}, nil
	case "stream-cancel":
		stream, err := session.Events(ctx, cmux.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		if err := stream.Cancel(ctx); err != nil {
			return nil, err
		}
		if err := stream.Cancel(ctx); err != nil {
			return nil, err
		}
		items := 0
		for {
			_, err := stream.Recv(ctx)
			if err == nil {
				items++
				continue
			}
			var observed *cmux.StreamEndError
			if !errors.As(err, &observed) && !errors.Is(err, cmux.ErrClosed) {
				return nil, err
			}
			break
		}
		terminal := stream.End()
		if terminal == nil {
			return nil, errors.New("cancel omitted terminal stream end")
		}
		return map[string]any{
			"end":                terminal.Reason,
			"items_after_cancel": items,
			"cancel_calls":       2,
		}, nil
	case "stream-overflow":
		first, err := session.Events(ctx, cmux.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		firstEnd, err := receiveEnd(ctx, first)
		if err != nil {
			return nil, err
		}
		second, err := session.Events(ctx, cmux.SessionEventsOptions{})
		if err != nil {
			return nil, err
		}
		secondItem, err := second.Recv(ctx)
		if err != nil {
			return nil, err
		}
		if _, err := receiveEnd(ctx, second); err != nil {
			return nil, err
		}
		document, err := session.Ping(ctx, cmux.SessionPingOptions{})
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"first_end":     firstEnd,
			"second_kind":   secondItem.Value.Kind,
			"control_alive": document.Fields["alive"],
		}, nil
	case "live-flow":
		return liveFlow(ctx, client, input)
	default:
		return nil, fmt.Errorf("unknown adapter operation %q", input.Op)
	}
}

func handles(
	client *cmux.Client,
	values constants,
) (*cmux.Session, *cmux.Workspace, error) {
	sessionID, err := cmux.ParseSessionID(values.Session)
	if err != nil {
		return nil, nil, err
	}
	workspaceID, err := cmux.ParseWorkspaceID(values.Workspace)
	if err != nil {
		return nil, nil, err
	}
	session := client.Machine(cmux.SelectCurrent[cmux.MachineID]()).
		Session(cmux.SelectID(sessionID))
	return session, session.Workspace(cmux.SelectID(workspaceID)), nil
}

func renameOptions(values constants) (cmux.WorkspaceRenameOptions, error) {
	revision, err := strconv.ParseUint(values.Revision, 10, 64)
	if err != nil {
		return cmux.WorkspaceRenameOptions{}, err
	}
	decimal := cmux.Decimal(revision)
	return cmux.WorkspaceRenameOptions{
		MutationOptions: cmux.MutationOptions{
			IdempotencyKey:   values.IdempotencyKey,
			ExpectedRevision: &decimal,
		},
		Name: values.Name,
	}, nil
}

func mutationValue(result cmux.MutationResult[cmux.WorkspaceSnapshot]) map[string]any {
	return map[string]any{
		"workspace_id": result.Value.ID,
		"name":         result.Value.Name,
		"generation":   result.Generation,
		"revision":     result.Revision.String(),
		"replayed":     result.Replayed,
	}
}

func cursorValue(cursor *cmux.Cursor) any {
	if cursor == nil {
		return nil
	}
	return map[string]any{
		"generation": cursor.Generation,
		"revision":   cursor.Revision.String(),
	}
}

func receiveEnd(
	ctx context.Context,
	stream *cmux.Stream[cmux.SessionEvent],
) (string, error) {
	for {
		_, err := stream.Recv(ctx)
		if err == nil {
			continue
		}
		var terminal *cmux.StreamEndError
		if errors.As(err, &terminal) {
			return terminal.Reason, nil
		}
		return "", err
	}
}

func normalize(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(typed))
		for key, item := range typed {
			result[key] = normalize(item)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, item := range typed {
			result[index] = normalize(item)
		}
		return result
	case json.Number:
		return typed.String()
	default:
		return value
	}
}

func redaction() (any, error) {
	const secret = "provider://conformance-secret"
	const token = "renderer-conformance-secret"
	specifier, err := cmux.NewExternalMachineSpecifier(secret)
	if err != nil {
		return nil, err
	}
	terminalID, err := cmux.ParseTerminalID(
		"term_66666666666666666666666666666666",
	)
	if err != nil {
		return nil, err
	}
	grant := cmux.RendererGrant{
		Endpoint:   "unix:///tmp/renderer",
		TerminalID: terminalID,
		Token:      cmux.NewSecret(token),
		Rights:     []string{"render"},
		TTLMS:      1000,
	}
	return map[string]any{
		"specifier_redacted":      !strings.Contains(fmt.Sprintf("%v %#v", specifier, specifier), secret),
		"renderer_token_redacted": !strings.Contains(fmt.Sprintf("%v %#v", grant, grant), token),
	}, nil
}

func liveFlow(ctx context.Context, client *cmux.Client, input request) (any, error) {
	session := client.Machine(cmux.SelectCurrent[cmux.MachineID]()).
		Session(cmux.SelectCurrent[cmux.SessionID]())
	ping, err := session.Ping(ctx, cmux.SessionPingOptions{})
	if err != nil {
		return nil, err
	}
	name := input.WorkspaceName
	created, err := session.CreateWorkspace(ctx, cmux.WorkspaceCreateOptions{
		MutationOptions: cmux.MutationOptions{IdempotencyKey: "live-create"},
		Name:            &name,
		InitialContent:  "empty",
	})
	if err != nil {
		return nil, err
	}
	workspace := session.Workspace(cmux.SelectID(created.Value.Workspace))
	renamedName := name + "-renamed"
	renamed, err := workspace.Rename(ctx, cmux.WorkspaceRenameOptions{
		MutationOptions: cmux.MutationOptions{IdempotencyKey: "live-rename"},
		Name:            renamedName,
	})
	if err != nil {
		return nil, err
	}
	listedValues, err := session.ListWorkspaces(ctx, cmux.WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	listed := false
	for index := range listedValues {
		if snapshot, ok := listedValues[index].Cached(); ok &&
			snapshot.ID == created.Value.Workspace {
			listed = true
		}
	}
	if _, err := workspace.Close(ctx, cmux.WorkspaceCloseOptions{
		MutationOptions: cmux.MutationOptions{IdempotencyKey: "live-close"},
	}); err != nil {
		return nil, err
	}
	remaining, err := session.ListWorkspaces(ctx, cmux.WorkspaceListOptions{})
	if err != nil {
		return nil, err
	}
	disappeared := true
	for index := range remaining {
		if snapshot, ok := remaining[index].Cached(); ok &&
			snapshot.ID == created.Value.Workspace {
			disappeared = false
		}
	}
	return map[string]any{
		"pinged":      ping.Fields["alive"],
		"created":     created.Value.Workspace != "",
		"renamed":     renamed.Value.Name == renamedName,
		"listed":      listed,
		"closed":      true,
		"disappeared": disappeared,
	}, nil
}
