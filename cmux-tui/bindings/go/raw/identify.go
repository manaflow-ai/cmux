package raw

import (
	"context"
	"fmt"
)

// Identify preserves the original request and response format.
func (c *Client) Identify(ctx context.Context) (IdentifyResult, error) {
	return c.IdentifyWith(ctx, IdentifyRequest{})
}

// IdentifyWith selects explicit metadata without changing Identify's zero-argument API.
func (c *Client) IdentifyWith(ctx context.Context, request IdentifyRequest) (IdentifyResult, error) {
	var result IdentifyResult
	params, err := commandMap(request)
	if err != nil {
		return result, fmt.Errorf("%w: encode identify parameters: %v", ErrInvalidArgument, err)
	}
	err = c.requestGenerated(ctx, commandMetadata["identify"], "identify", params, &result)
	return result, err
}
