package raw

import (
	"context"
	"fmt"
)

// ListWorkspaces returns the whole tree, as before `known` existed.
func (c *Client) ListWorkspaces(ctx context.Context) (ListWorkspacesResult, error) {
	return c.ListWorkspacesWith(ctx, ListWorkspacesRequest{})
}

// ListWorkspacesWith sends `known` (list-workspaces-known-v1) or `limit`
// (list-workspaces-limit-v1) without changing
// ListWorkspaces's zero-argument API. A result with Unchanged set has no
// workspaces: keep the tree the request named.
func (c *Client) ListWorkspacesWith(ctx context.Context, request ListWorkspacesRequest) (ListWorkspacesResult, error) {
	var result ListWorkspacesResult
	params, err := commandMap(request)
	if err != nil {
		return result, fmt.Errorf("%w: encode list-workspaces parameters: %v", ErrInvalidArgument, err)
	}
	err = c.requestGenerated(ctx, commandMetadata["list-workspaces"], "list-workspaces", params, &result)
	return result, err
}
