package cmux

import (
	"encoding/base64"
	"encoding/json"
)

// IdentifyDetails is retained as an alias for the now-complete generated
// identify result.
type IdentifyDetails = IdentifyResult

// ClientSurfaceSize is retained as a compatibility alias.
type ClientSurfaceSize = ClientSize

// SelectOptions is retained for code that shares one selector value between
// screen and workspace selection.
type SelectOptions = SelectWorkspaceOptions

// SendOptions accepts either already encoded wire bytes or ordinary Go bytes.
// Text is sent first when Text and Bytes are both present.
type SendOptions struct {
	Text        *string
	Bytes       []byte
	Base64Bytes Base64
	Paste       bool
}

type TreeEventMode string

const (
	TreeEventsCoarse TreeEventMode = "coarse"
	TreeEventsDeltas TreeEventMode = "deltas"
)

type SubscribeOptions struct {
	TreeEvents TreeEventMode
	Surface    *ID
}

type AttachMode string

const (
	AttachBytes  AttachMode = "bytes"
	AttachRender AttachMode = "render"
)

type AttachSurfaceOptions struct {
	Mode AttachMode
	Cols *uint16
	Rows *uint16
}

// DecodeBase64 decodes an exact base64 wire field.
func DecodeBase64(value Base64) ([]byte, error) {
	return base64.StdEncoding.DecodeString(string(value))
}

// EncodeBase64 encodes bytes for an exact base64 wire field.
func EncodeBase64(value []byte) Base64 {
	return Base64(base64.StdEncoding.EncodeToString(value))
}

func (result *ResizeSurfaceResult) UnmarshalJSON(data []byte) error {
	type wireResult ResizeSurfaceResult
	decoded := wireResult{Accepted: true}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*result = ResizeSurfaceResult(decoded)
	return nil
}
