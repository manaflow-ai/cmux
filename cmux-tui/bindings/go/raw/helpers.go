package raw

import (
	"encoding/base64"
)

// IdentifyDetails is retained as an alias for the now-complete generated
// identify result.
type IdentifyDetails = IdentifyResult

// ClientSurfaceSize is retained as a compatibility alias.
type ClientSurfaceSize = ClientSize

// SelectOptions is retained for code that shares one selector value between
// screen and workspace selection.
type SelectOptions = SelectWorkspaceOptions

// SendOptions preserves omitted, null, and value states for the nullable text
// and bytes wire fields. Use EncodeBase64 before wrapping ordinary bytes.
type SendOptions struct {
	Text  Presence[string]
	Bytes Presence[Base64]
	Paste *bool
}

type TreeEventMode string

const (
	TreeEventsCoarse TreeEventMode = "coarse"
	TreeEventsDeltas TreeEventMode = "deltas"
)

type SubscribeOptions struct {
	TreeEvents Presence[TreeEventMode]
	Surface    Presence[ID]
}

type AttachMode string

const (
	AttachBytes  AttachMode = "bytes"
	AttachRender AttachMode = "render"
)

type AttachSurfaceOptions struct {
	Mode Presence[AttachMode]
	Cols Presence[uint16]
	Rows Presence[uint16]
}

// DecodeBase64 decodes an exact base64 wire field.
func DecodeBase64(value Base64) ([]byte, error) {
	return base64.StdEncoding.DecodeString(string(value))
}

// EncodeBase64 encodes bytes for an exact base64 wire field.
func EncodeBase64(value []byte) Base64 {
	return Base64(base64.StdEncoding.EncodeToString(value))
}
