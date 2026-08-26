package raw

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// MaxScrollbackPageRows is the protocol limit for one read-scrollback page.
const MaxScrollbackPageRows uint32 = 65_535

// RenderRunPlainText returns a run's text without its render attributes.
func RenderRunPlainText(run RenderRun) string {
	return run.Text
}

// RenderRowPlainText concatenates a row's ordered runs without a newline.
func RenderRowPlainText(row RenderRow) string {
	var text strings.Builder
	for _, run := range row.Runs {
		text.WriteString(RenderRunPlainText(run))
	}
	return text.String()
}

// RenderRowsPlainText joins rows with one newline and no trailing newline.
func RenderRowsPlainText(rows []RenderRow) string {
	var text strings.Builder
	for index, row := range rows {
		if index > 0 {
			text.WriteByte('\n')
		}
		text.WriteString(RenderRowPlainText(row))
	}
	return text.String()
}

// ReadScrollbackTail reads up to count rows from the current retained tail.
//
// The helper first sends a zero-count probe, then reads a page ending at the
// probed total. These are two independent snapshots. Concurrent output,
// eviction, or resize reflow can shift the second range, and the returned
// second snapshot is authoritative.
func (c *Client) ReadScrollbackTail(
	ctx context.Context,
	surface ID,
	count uint32,
) (ReadScrollbackResult, error) {
	if count > MaxScrollbackPageRows {
		return ReadScrollbackResult{}, fmt.Errorf(
			"%w: scrollback row count must be between 0 and %d",
			ErrInvalidArgument,
			MaxScrollbackPageRows,
		)
	}
	probe, err := c.ReadScrollback(ctx, surface, 0, 0)
	if err != nil || count == 0 {
		return probe, err
	}
	start := uint32(0)
	if probe.Total > count {
		start = probe.Total - count
	}
	return c.ReadScrollback(ctx, surface, start, count)
}

// WorkspaceLeaseOptions identifies one caller-owned workspace lifecycle.
//
// Persist Key, Origin, and both mutation IDs before the first call. Reuse the
// same values after an ambiguous transport failure. Use a fresh key and fresh
// mutation IDs after the lease has been closed because workspace keys are
// permanently tombstoned.
type WorkspaceLeaseOptions struct {
	Key              string
	Name             *string
	Origin           string
	CreateMutationID string
	CloseMutationID  string
}

// WorkspaceLease owns a stable workspace key discovered or created by
// DiscoverOrCreateWorkspace. Its close operation is idempotent and may be
// retried with a replacement Client through CloseWith.
type WorkspaceLease struct {
	client            *Client
	workspace         ID
	key               string
	workspaceRevision uint64
	created           bool
	replayed          bool
	origin            string
	closeMutationID   string

	mu     sync.Mutex
	closed bool
}

// DiscoverOrCreateWorkspace returns the live workspace with the caller-owned
// key, or creates it with a durable mutation identity.
//
// A matching key is treated as owned by the caller. The protocol snapshot does
// not expose the origin that created a workspace, so callers must never pass an
// arbitrary third-party key. The method is safe to repeat with the same
// options, including on a replacement Client after a lost create response.
func (c *Client) DiscoverOrCreateWorkspace(
	ctx context.Context,
	options WorkspaceLeaseOptions,
) (*WorkspaceLease, error) {
	if err := validateWorkspaceLeaseOptions(options); err != nil {
		return nil, err
	}
	tree, err := c.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	for _, workspace := range tree.Workspaces {
		if workspace.Key != nil && *workspace.Key == options.Key {
			return newWorkspaceLease(
				c,
				workspace.ID,
				options.Key,
				optionalUint64(tree.WorkspaceRevision),
				false,
				false,
				options,
			), nil
		}
	}

	key := options.Key
	origin := options.Origin
	mutationID := options.CreateMutationID
	created, err := c.CreateWorkspace(ctx, CreateWorkspaceOptions{
		Key:        Value(key),
		MutationID: Value(mutationID),
		Name:       presenceFromPointer(options.Name),
		Origin:     Value(origin),
	})
	if err != nil {
		return nil, err
	}
	return newWorkspaceLease(
		c,
		created.Workspace,
		created.Key,
		created.WorkspaceRevision,
		!created.Replayed,
		created.Replayed,
		options,
	), nil
}

func newWorkspaceLease(
	client *Client,
	workspace ID,
	key string,
	workspaceRevision uint64,
	created bool,
	replayed bool,
	options WorkspaceLeaseOptions,
) *WorkspaceLease {
	return &WorkspaceLease{
		client:            client,
		workspace:         workspace,
		key:               key,
		workspaceRevision: workspaceRevision,
		created:           created,
		replayed:          replayed,
		origin:            options.Origin,
		closeMutationID:   options.CloseMutationID,
	}
}

// Workspace returns the daemon-local numeric workspace ID.
func (lease *WorkspaceLease) Workspace() ID {
	lease.mu.Lock()
	defer lease.mu.Unlock()
	return lease.workspace
}

// Key returns the canonical stable workspace key.
func (lease *WorkspaceLease) Key() string {
	return lease.key
}

// WorkspaceRevision returns the revision from the create result or discovery
// snapshot.
func (lease *WorkspaceLease) WorkspaceRevision() uint64 {
	lease.mu.Lock()
	defer lease.mu.Unlock()
	return lease.workspaceRevision
}

// Created reports whether this call committed a new create mutation.
func (lease *WorkspaceLease) Created() bool {
	return lease.created
}

// Replayed reports whether the server replayed an earlier create receipt.
func (lease *WorkspaceLease) Replayed() bool {
	return lease.replayed
}

// Closed reports whether a close succeeded or a current snapshot showed the
// workspace already absent.
func (lease *WorkspaceLease) Closed() bool {
	lease.mu.Lock()
	defer lease.mu.Unlock()
	return lease.closed
}

// Close closes the workspace with the client that acquired the lease.
// Successful and already-absent closes are idempotent. A failed close remains
// retryable.
func (lease *WorkspaceLease) Close(ctx context.Context) error {
	return lease.CloseWith(ctx, lease.client)
}

// CloseWith closes the workspace through client. Use this form after replacing
// a failed transport. It reconciles the live key before sending the durable
// close mutation and leaves the lease retryable on failure.
func (lease *WorkspaceLease) CloseWith(ctx context.Context, client *Client) error {
	if client == nil {
		return fmt.Errorf("%w: workspace lease client is nil", ErrInvalidArgument)
	}
	lease.mu.Lock()
	defer lease.mu.Unlock()
	if lease.closed {
		return nil
	}

	tree, err := client.ListWorkspaces(ctx)
	if err != nil {
		return err
	}
	var live *Workspace
	for index := range tree.Workspaces {
		workspace := &tree.Workspaces[index]
		if workspace.Key != nil && *workspace.Key == lease.key {
			live = workspace
			break
		}
	}
	if live == nil {
		lease.closed = true
		return nil
	}

	key := lease.key
	origin := lease.origin
	mutationID := lease.closeMutationID
	workspace := live.ID
	closed, err := client.CloseWorkspace(ctx, CloseWorkspaceOptions{
		ExpectedGeneration: presenceFromPointer(tree.Generation),
		ExpectedRevision:   presenceFromPointer(tree.WorkspaceRevision),
		Key:                Value(key),
		MutationID:         Value(mutationID),
		Origin:             Value(origin),
		Workspace:          Value(workspace),
	})
	if err != nil {
		return err
	}
	lease.workspace = closed.Workspace
	lease.workspaceRevision = closed.WorkspaceRevision
	lease.closed = true
	return nil
}

func validateWorkspaceLeaseOptions(options WorkspaceLeaseOptions) error {
	if !isCanonicalWorkspaceKey(options.Key) {
		return fmt.Errorf(
			"%w: workspace lease key must be a lowercase canonical UUID",
			ErrInvalidArgument,
		)
	}
	if err := validateMutationIdentifier("origin", options.Origin); err != nil {
		return err
	}
	if err := validateMutationIdentifier(
		"create mutation ID",
		options.CreateMutationID,
	); err != nil {
		return err
	}
	if err := validateMutationIdentifier(
		"close mutation ID",
		options.CloseMutationID,
	); err != nil {
		return err
	}
	if options.CreateMutationID == options.CloseMutationID {
		return fmt.Errorf(
			"%w: create and close mutation IDs must differ",
			ErrInvalidArgument,
		)
	}
	if options.Name != nil {
		if !utf8.ValidString(*options.Name) {
			return fmt.Errorf(
				"%w: workspace name must be valid UTF-8",
				ErrInvalidArgument,
			)
		}
		if len(*options.Name) > 1_024 {
			return fmt.Errorf(
				"%w: workspace name exceeds 1024 UTF-8 bytes",
				ErrInvalidArgument,
			)
		}
	}
	return nil
}

func validateMutationIdentifier(label, value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("%w: %s cannot be empty", ErrInvalidArgument, label)
	}
	if !utf8.ValidString(value) {
		return fmt.Errorf("%w: %s must be valid UTF-8", ErrInvalidArgument, label)
	}
	if len(value) > 128 {
		return fmt.Errorf(
			"%w: %s exceeds 128 UTF-8 bytes",
			ErrInvalidArgument,
			label,
		)
	}
	if strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return fmt.Errorf(
			"%w: %s contains a control character",
			ErrInvalidArgument,
			label,
		)
	}
	return nil
}

func isCanonicalWorkspaceKey(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index := range value {
		switch index {
		case 8, 13, 18, 23:
			if value[index] != '-' {
				return false
			}
		default:
			if (value[index] < '0' || value[index] > '9') &&
				(value[index] < 'a' || value[index] > 'f') {
				return false
			}
		}
	}
	return true
}

func optionalUint64(value *uint64) uint64 {
	if value == nil {
		return 0
	}
	return *value
}

func presenceFromPointer[T any](value *T) Presence[T] {
	if value == nil {
		return Presence[T]{}
	}
	return Value(*value)
}
